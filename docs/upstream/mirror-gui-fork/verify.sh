#!/usr/bin/env bash
# Run inside the Stream 9 Lima VM (limactl shell mirror-gui-stream9).
# 1. Tests that need no Red Hat login: unit, integration, shellcheck.
# 2. With a pull secret at ~/pull-secret.json: build and start the container, then check
#    that the port listens on 127.0.0.1 only, and that a mirror run verifies TLS.
set -euo pipefail

FORK_URL="${FORK_URL:-https://github.com/ephico2real2/mirror-gui.git}"
BRANCH="${BRANCH:-fix/tls-deps-bind}"
WORKDIR="${WORKDIR:-$HOME/mirror-gui}"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/patches"

step() { printf '\n== %s\n' "$*"; }

step "Source: $FORK_URL ($BRANCH), or upstream plus the patches in $PATCH_DIR"
rm -rf "$WORKDIR"
if git clone -q --branch "$BRANCH" "$FORK_URL" "$WORKDIR" 2>/dev/null; then
  echo "cloned the fork"
else
  git clone -q https://github.com/openshift/mirror-gui.git "$WORKDIR"
  git -C "$WORKDIR" checkout -q 3cec34f
  git -C "$WORKDIR" -c user.name=verify -c user.email=verify@localhost am -q "$PATCH_DIR"/*.patch
  echo "applied $(find "$PATCH_DIR" -name "*.patch" | wc -l) patches on upstream 3cec34f"
fi
cd "$WORKDIR"

step "Unit and integration tests"
npm ci --no-audit --no-fund
npx vitest run

step "ShellCheck (error level, as CI)"
shellcheck -S error mirror-gui.sh entrypoint.sh local-build.sh sync-catalogs.sh

if [ ! -f "$HOME/pull-secret.json" ]; then
  echo
  echo "No ~/pull-secret.json: skipping the container checks."
  echo "Copy your Red Hat pull secret there and run this script again for them."
  exit 0
fi

step "Build and start the container (syncs catalogs from registry.redhat.io; takes a while)"
mkdir -p pull-secret && cp "$HOME/pull-secret.json" pull-secret/pull-secret.json
./local-build.sh

step "Port binding: only 127.0.0.1 may listen on 3000"
listeners="$(ss -ltnH 'sport = :3000' | awk '{print $4}')"
echo "$listeners"
if echo "$listeners" | grep -qvE '^(127\.0\.0\.1|\[::1\]):3000$'; then
  echo "FAIL: port 3000 listens beyond loopback"; exit 1
fi
curl -fsS -o /dev/null http://127.0.0.1:3000/api/health && echo "reachable on 127.0.0.1"
vm_ip="$(hostname -I | awk '{print $1}')"
if curl -fsS -m 5 -o /dev/null "http://$vm_ip:3000/api/health"; then
  echo "FAIL: reachable on $vm_ip"; exit 1
fi
echo "not reachable on $vm_ip"

step "TLS: a mirror run must not pass --src-tls-verify=false or --dest-tls-verify=false"
cat > /tmp/verify-isc.yaml <<'ISC'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi-minimal:latest
ISC
curl -fsS -X POST http://127.0.0.1:3000/api/config/save -H 'Content-Type: application/json' \
  -d "$(jq -n --rawfile c /tmp/verify-isc.yaml '{config: $c, name: "verify-tls.yaml"}')" >/dev/null
op="$(curl -fsS -X POST http://127.0.0.1:3000/api/operations/start -H 'Content-Type: application/json' \
  -d '{"configFile":"verify-tls.yaml"}' | jq -r '.operationId // .data.id')"
sleep 5
args="$(podman exec mirror-gui sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline 2>/dev/null; echo; done' | grep '[o]c-mirror --v2' || true)"
echo "$args"
if echo "$args" | grep -q 'tls-verify=false'; then
  echo "FAIL: TLS verification disabled"; exit 1
fi
[ -n "$args" ] && echo "oc-mirror runs with TLS verification on" || echo "oc-mirror already finished; check the operation log for $op"
curl -fsS -X POST "http://127.0.0.1:3000/api/operations/$op/stop" >/dev/null || true

step "All checks passed"
