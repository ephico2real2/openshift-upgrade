#!/usr/bin/env bash
# install-cli-tools.sh: install tmux, ansible-core and jq from dnf, and oc, kubectl and oc-mirror from the
# Red Hat tarballs in a tools folder, on a RHEL 9 family host.
#
# Each path is a variable with a default. Override one on the command line, for example:
#   BIN_DIR=/opt/bin TOOLS_DIR=/data/tools bash install-cli-tools.sh
#
# The mirror registry tarball is out of scope: it is installed in its own step.

set -euo pipefail

readonly PROG=install-cli-tools

TOOLS_DIR=${TOOLS_DIR:-/root/tools}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
OC_TARBALL=${OC_TARBALL:-${TOOLS_DIR}/openshift-client-linux-amd64-rhel9.tar.gz}
OC_MIRROR_TARBALL=${OC_MIRROR_TARBALL:-${TOOLS_DIR}/oc-mirror-rhel9-linux-amd64.tar.gz}

# Packages from the OS repositories. tmux keeps long jobs (mirror-registry install, oc-mirror runs)
# running when the SSH connection drops. ansible-core gives ansible-vault and the oc-mirror playbooks;
# jq reads the pull secret.
readonly PACKAGES=(tmux ansible-core jq)

# Files that each tarball must contain. The script stops if one is missing.
readonly OC_FILES=(oc kubectl)
readonly OC_MIRROR_FILES=(oc-mirror)

work_dir=""

log() { printf '[%s] %s\n' "$PROG" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }
cleanup() { if [[ -n "$work_dir" ]]; then rm -rf "$work_dir"; fi; }
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: [VAR=value ...] install-cli-tools.sh

Installs ${PACKAGES[*]} with dnf, and oc and kubectl (from OC_TARBALL) and oc-mirror
(from OC_MIRROR_TARBALL) into BIN_DIR.

Variables and their values now:
  TOOLS_DIR          ${TOOLS_DIR}
  BIN_DIR            ${BIN_DIR}
  OC_TARBALL         ${OC_TARBALL}
  OC_MIRROR_TARBALL  ${OC_MIRROR_TARBALL}

Run as root. Safe to run again: unchanged files are not replaced.
EOF
}

check_host() {
  [[ $EUID -eq 0 ]] || die "run as root"
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    rhel|rocky|almalinux|centos) ;;
    *) die "RHEL 9 family only; this host is ${PRETTY_NAME:-unknown}" ;;
  esac
  # The tarballs hold the rhel9 builds of oc and oc-mirror, linked against RHEL 9 libraries.
  [[ "${VERSION_ID%%.*}" == 9 ]] || die "RHEL 9 family only; this host is ${PRETTY_NAME}"
  [[ "$(uname -m)" == x86_64 ]] || die "the tarballs are amd64 builds; this host is $(uname -m)"
  log "host: ${PRETTY_NAME}"
}

# dnf skips a package that is already installed, so a second run changes nothing.
install_packages() {
  log "installing: ${PACKAGES[*]}"
  dnf install -y "${PACKAGES[@]}"
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    log "installed: $(rpm -q "$pkg")"
  done
}

# Fails with the missing names when a tarball lacks a file the step needs.
check_tarball() {
  local tarball=$1
  shift
  [[ -f "$tarball" ]] || die "tarball not found: $tarball"
  local listing missing=() name
  listing=$(tar -tzf "$tarball") || die "cannot read tarball: $tarball"
  for name in "$@"; do
    grep -qx -- "$name" <<<"$listing" || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "$tarball lacks: ${missing[*]}"
  log "checked: $tarball (sha256 $(sha256sum "$tarball" | cut -d' ' -f1))"
}

# Extracts the named files to a private temporary folder and installs them into BIN_DIR.
# `install -C` leaves a target alone when its content and mode already match.
install_binaries() {
  local tarball=$1
  shift
  local dest
  dest="${work_dir}/$(basename "$tarball")"
  mkdir -p "$dest"
  tar -xzf "$tarball" -C "$dest" -- "$@"
  local name
  for name in "$@"; do
    install -C -m 0755 "${dest}/${name}" "${BIN_DIR}/${name}"
    log "installed: ${BIN_DIR}/${name}"
  done
}

# Reads a "key":value pair from JSON on stdin, without jq (jq is not a dependency of this script).
json_field() { tr -d '\n ' | grep -o "\"$1\":\(\"[^\"]*\"\|\[[^]]*\]\)" | head -1 | cut -d: -f2- | tr -d '"'; }

report_versions() {
  log "tmux:      $(tmux -V)"
  log "ansible:   $(ansible-vault --version | head -1)"
  log "jq:        $(jq --version)"
  log "oc:        $("${BIN_DIR}/oc" version --client 2>&1 | head -1)"
  log "kubectl:   $("${BIN_DIR}/kubectl" version --client 2>&1 | head -1)"
  # oc-mirror prints a greeting on stderr; the JSON on stdout holds the version.
  local mirror_json
  mirror_json=$("${BIN_DIR}/oc-mirror" version --output=json 2>/dev/null)
  log "oc-mirror: $(json_field gitVersion <<<"$mirror_json")"
  log "oc-mirror supports OpenShift: $(json_field supportedOCPVersions <<<"$mirror_json")"
  if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
    log "note: ${BIN_DIR} is not in PATH for this shell"
  fi
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; die "unknown argument: $1 (set paths with variables, see --help)" ;;
  esac
  check_host
  check_tarball "$OC_TARBALL" "${OC_FILES[@]}"
  check_tarball "$OC_MIRROR_TARBALL" "${OC_MIRROR_FILES[@]}"
  install_packages
  install -d -m 0755 "$BIN_DIR"
  work_dir=$(mktemp -d)
  install_binaries "$OC_TARBALL" "${OC_FILES[@]}"
  install_binaries "$OC_MIRROR_TARBALL" "${OC_MIRROR_FILES[@]}"
  report_versions
  log "done"
}

main "$@"
