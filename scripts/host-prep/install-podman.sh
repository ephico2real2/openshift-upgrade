#!/usr/bin/env bash
# install-podman.sh: install Podman on a RHEL 9 family host and set the rootless network command.
#
# Implements "4.3. Configure rootless Podman networking" of the OpenShift disconnected-environments docs.
# From RHEL 9.5 (Podman 5) the rootless default is pasta, which fails on hosts without a default route:
#   Error: pasta failed with exit code 1: External interface not usable
# The fix sets default_rootless_network_cmd = "slirp4netns" in the [network] table of containers.conf.
#
# The setting goes in a drop-in file, not in /etc/containers/containers.conf, so that a package update
# never conflicts with it. Rootful Podman (root) is not affected by this setting.
#
# Usage: see usage() below, or run with --help.

set -euo pipefail

readonly PROG=install-podman
readonly DROPIN_DIR=/etc/containers/containers.conf.d
readonly DROPIN="${DROPIN_DIR}/50-rootless-network.conf"
readonly PACKAGES=(podman slirp4netns passt container-selinux)
readonly TEST_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
readonly TEST_URL=https://registry.access.redhat.com/

network_cmd=slirp4netns
run_test=false
stop_containers=false
users=()

log() { printf '[%s] %s\n' "$PROG" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install-podman.sh [--user NAME]... [--network-cmd slirp4netns|pasta] [--test] [--stop-containers]

Installs podman, slirp4netns, passt and container-selinux, and sets the rootless network command
for all users in /etc/containers/containers.conf.d/50-rootless-network.conf.

  --user NAME         Rootless user to migrate and check. Repeat for more users.
  --network-cmd CMD   slirp4netns (default, the Red Hat fix) or pasta (the Podman 5 default).
  --test              For each --user, run a container that makes an HTTPS request.
  --stop-containers   Allow `podman system migrate` to stop the running containers of a --user.
  -h, --help          Show this help.

Run as root. Safe to run again: unchanged files are not written.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --user)            [[ $# -ge 2 ]] || die "--user needs a name"; users+=("$2"); shift 2 ;;
      --network-cmd)     [[ $# -ge 2 ]] || die "--network-cmd needs a value"; network_cmd=$2; shift 2 ;;
      --test)            run_test=true; shift ;;
      --stop-containers) stop_containers=true; shift ;;
      -h|--help)         usage; exit 0 ;;
      *)                 usage >&2; die "unknown argument: $1" ;;
    esac
  done
  case "$network_cmd" in
    slirp4netns|pasta) ;;
    *) die "--network-cmd must be slirp4netns or pasta, not '$network_cmd'" ;;
  esac
  if $run_test && ((${#users[@]} == 0)); then
    die "--test needs at least one --user, because the test runs rootless"
  fi
}

check_host() {
  [[ $EUID -eq 0 ]] || die "run as root"
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing; cannot identify the OS"
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    rhel|rocky|almalinux|centos) ;;
    *) die "RHEL 9 family only; this host is ${PRETTY_NAME:-unknown}" ;;
  esac
  # Podman 6 (RHEL 10 and later) removes slirp4netns, so the fix applies to the RHEL 9 line only.
  [[ "${VERSION_ID%%.*}" == 9 ]] || die "RHEL 9 family only; this host is ${PRETTY_NAME}"
  log "host: ${PRETTY_NAME}"
}

install_packages() {
  log "installing: ${PACKAGES[*]}"
  dnf install -y "${PACKAGES[@]}"
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    log "installed: $(rpm -q "$pkg")"
  done
}

write_dropin() {
  local content
  content=$(cat <<EOF
# Written by ${PROG}.sh. Rootless network command, per OpenShift docs
# "Configure rootless Podman networking". Podman reads this after containers.conf.
[network]
default_rootless_network_cmd = "${network_cmd}"
EOF
)
  if [[ -f "$DROPIN" ]] && [[ "$(<"$DROPIN")" == "$content" ]]; then
    log "unchanged: $DROPIN"
    return
  fi
  install -d -m 0755 "$DROPIN_DIR"
  if [[ -f "$DROPIN" ]]; then
    local backup
    backup="${DROPIN}.bak.$(date +%Y%m%dT%H%M%S)"
    cp -a "$DROPIN" "$backup"
    log "backup: $backup"
  fi
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$content" >"$tmp"
  install -m 0644 "$tmp" "$DROPIN"
  rm -f "$tmp"
  if command -v selinuxenabled >/dev/null && selinuxenabled; then
    restorecon "$DROPIN"
  fi
  log "wrote: $DROPIN (default_rootless_network_cmd = \"${network_cmd}\")"
}

# Runs a command as a rootless user in a login shell. Podman needs the user's HOME, and it uses
# XDG_RUNTIME_DIR when the user has a systemd session or linger (/run/user/<uid>).
run_as() {
  local user=$1
  shift
  local uid env_args=()
  uid=$(id -u "$user")
  if [[ -d "/run/user/${uid}" ]]; then
    env_args=("XDG_RUNTIME_DIR=/run/user/${uid}")
  fi
  runuser -l "$user" -c "$(printf '%q ' env "${env_args[@]}" "$@")"
}

check_user() {
  local user=$1
  id "$user" >/dev/null 2>&1 || die "user '$user' does not exist"
  [[ "$(id -u "$user")" -ne 0 ]] || die "'$user' is root; this setting applies to rootless users only"
  # Rootless Podman maps container IDs through subordinate IDs; without them it cannot start.
  grep -q "^${user}:" /etc/subuid || die "'$user' has no entry in /etc/subuid; run: usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user"
  grep -q "^${user}:" /etc/subgid || die "'$user' has no entry in /etc/subgid; run: usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user"
}

migrate_user() {
  local user=$1 running
  running=$(run_as "$user" podman ps -q | wc -l)
  if ((running > 0)) && ! $stop_containers; then
    die "'$user' has $running running container(s); 'podman system migrate' stops them. Stop them first, or pass --stop-containers"
  fi
  log "$user: podman system migrate ($running running container(s) to stop)"
  run_as "$user" podman system migrate
}

verify_user() {
  local user=$1 effective
  effective=$(run_as "$user" podman info --format '{{.Host.RootlessNetworkCmd}}')
  if [[ "$effective" != "$network_cmd" ]]; then
    die "$user: effective rootless network command is '$effective', expected '$network_cmd'. A user file (~${user}/.config/containers/containers.conf) can override $DROPIN"
  fi
  log "$user: effective rootless network command: $effective"
}

# Proves the network path only: any HTTP status means that the request left the container and a reply
# came back. A network failure makes curl exit non-zero with status 000. The page content is not tested.
test_user() {
  local user=$1 code
  log "$user: test container ($TEST_IMAGE) requests $TEST_URL"
  code=$(run_as "$user" podman run --rm --pull=missing "$TEST_IMAGE" \
    curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$TEST_URL") \
    || die "$user: the test container could not reach $TEST_URL (HTTP '${code:-none}')"
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || die "$user: the test request returned no HTTP status ('$code')"
  log "$user: test passed: HTTP $code from $TEST_URL through $network_cmd"
}

main() {
  parse_args "$@"
  check_host
  install_packages
  write_dropin
  local user
  for user in "${users[@]}"; do
    check_user "$user"
    migrate_user "$user"
    verify_user "$user"
    if $run_test; then
      test_user "$user"
    fi
  done
  log "done: $(podman --version)"
}

main "$@"
