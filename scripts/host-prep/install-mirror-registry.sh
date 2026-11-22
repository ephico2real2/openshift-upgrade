#!/usr/bin/env bash
# install-mirror-registry.sh: install the Red Hat mirror registry (Quay) on this host, with all its data
# under one folder (REGISTRY_DATA, default /registry-data).
#
# mirror-registry 2.0 keeps data in three places, so the script sets all three:
#   --quayRoot       configuration, certificates, installer state  (default ~/quay-install)
#   --quayStorage    the image blobs                               (default Podman volume quay-storage)
#   --sqliteStorage  the SQLite database                           (default Podman volume sqlite-storage)
#
# Usage: QUAY_HOSTNAME=registry.example.com bash install-mirror-registry.sh [--dry-run]
# Run with --help for the variables and their values.

set -euo pipefail

readonly PROG=install-mirror-registry

REGISTRY_DATA=${REGISTRY_DATA:-/registry-data}
TOOLS_DIR=${TOOLS_DIR:-/root/tools}
MIRROR_REGISTRY_TARBALL=${MIRROR_REGISTRY_TARBALL:-${TOOLS_DIR}/mirror-registry-amd64.tar.gz}
MIRROR_REGISTRY_DIR=${MIRROR_REGISTRY_DIR:-${REGISTRY_DATA}/mirror-registry}
QUAY_HOSTNAME=${QUAY_HOSTNAME:-}
QUAY_PORT=${QUAY_PORT:-8443}
QUAY_ROOT=${QUAY_ROOT:-${REGISTRY_DATA}/quay-install}
QUAY_STORAGE=${QUAY_STORAGE:-${REGISTRY_DATA}/quay-storage}
SQLITE_STORAGE=${SQLITE_STORAGE:-${REGISTRY_DATA}/sqlite-storage}
INIT_USER=${INIT_USER:-init}
INIT_PASSWORD=${INIT_PASSWORD:-}
SSL_CERT=${SSL_CERT:-}
SSL_KEY=${SSL_KEY:-}

# Files that the tarball must contain. The installer reads the archives from its own folder.
readonly INSTALLER_FILES=(mirror-registry image-archive.tar execution-environment.tar sqlite3.tar)

dry_run=false
quay_host=""
install_cmd=()

log() { printf '[%s] %s\n' "$PROG" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: QUAY_HOSTNAME=<fqdn> [VAR=value ...] install-mirror-registry.sh [--dry-run]

  --dry-run   Run every check and print the install command. Change nothing.
  -h, --help  Show this help.

Variables and their values now:
  REGISTRY_DATA            ${REGISTRY_DATA}
  TOOLS_DIR                ${TOOLS_DIR}
  MIRROR_REGISTRY_TARBALL  ${MIRROR_REGISTRY_TARBALL}
  MIRROR_REGISTRY_DIR      ${MIRROR_REGISTRY_DIR}  (the unpacked installer)
  QUAY_HOSTNAME            ${QUAY_HOSTNAME:-<required>}  (FQDN, without port)
  QUAY_PORT                ${QUAY_PORT}
  QUAY_ROOT                ${QUAY_ROOT}
  QUAY_STORAGE             ${QUAY_STORAGE}
  SQLITE_STORAGE           ${SQLITE_STORAGE}
  INIT_USER                ${INIT_USER}
  INIT_PASSWORD            ${INIT_PASSWORD:+<set>}${INIT_PASSWORD:-<empty: the installer makes one>}
  SSL_CERT, SSL_KEY        ${SSL_CERT:-<empty>}, ${SSL_KEY:-<empty>}  (empty: the installer makes a certificate)

Run as root.
EOF
}

parse_args() {
  case "${1:-}" in
    --dry-run) dry_run=true ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; die "unknown argument: $1 (set values with variables, see --help)" ;;
  esac
  [[ $# -le 1 ]] || die "too many arguments"
}

check_host() {
  [[ $EUID -eq 0 ]] || die "run as root"
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    rhel|rocky|almalinux|centos) ;;
    *) die "RHEL 9 family only; this host is ${PRETTY_NAME:-unknown}" ;;
  esac
  [[ "${VERSION_ID%%.*}" == 9 ]] || die "RHEL 9 family only; this host is ${PRETTY_NAME}"
  local cmd
  for cmd in podman openssl ssh-keygen; do
    command -v "$cmd" >/dev/null || die "$cmd is missing (podman: run install-podman.sh first)"
  done
  log "host: ${PRETTY_NAME}, $(podman --version)"
}

check_inputs() {
  [[ -n "$QUAY_HOSTNAME" ]] || die "set QUAY_HOSTNAME to the registry FQDN, for example QUAY_HOSTNAME=registry.example.com"
  [[ "$QUAY_HOSTNAME" != *:* ]] || die "QUAY_HOSTNAME must not hold a port; set QUAY_PORT instead"
  # The installer does not accept an IP address as the host name.
  [[ ! "$QUAY_HOSTNAME" =~ ^[0-9.]+$ ]] || die "QUAY_HOSTNAME must be a name, not an IP address"
  [[ "$QUAY_HOSTNAME" == *.* ]] || die "QUAY_HOSTNAME must be a fully qualified name: $QUAY_HOSTNAME"
  quay_host="${QUAY_HOSTNAME}:${QUAY_PORT}"
  if [[ -n "$SSL_CERT" || -n "$SSL_KEY" ]]; then
    [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]] || die "set both SSL_CERT and SSL_KEY to existing files, or neither"
    openssl x509 -in "$SSL_CERT" -noout -checkhost "$QUAY_HOSTNAME" | grep -q 'does match' \
      || die "$SSL_CERT is not valid for $QUAY_HOSTNAME"
  fi
}

# The installer's last step contacts Quay at QUAY_HOSTNAME, so the name must resolve to this host.
# /etc/hosts counts: getent reads it before DNS.
check_name_resolution() {
  local resolved local_addrs addr match=false
  resolved=$(getent ahosts "$QUAY_HOSTNAME" | awk '{print $1}' | sort -u) \
    || die "$QUAY_HOSTNAME does not resolve. Create its DNS record (or an /etc/hosts line) first"
  local_addrs=$(ip -o addr show | awk '{sub(/\/.*/, "", $4); print $4}')
  for addr in $resolved; do
    grep -qxF "$addr" <<<"$local_addrs" && match=true
  done
  $match || die "$QUAY_HOSTNAME resolves to $(echo "$resolved" | tr '\n' ' ')which is not an address of this host. Point its DNS record here (Cloudflare: DNS only, not proxied)"
  log "name: $QUAY_HOSTNAME resolves to this host ($(echo "$resolved" | tr '\n' ' '))"

  # The installer connects over SSH to the target host, which defaults to this host's short name.
  getent hosts "$(hostname)" >/dev/null || die "the host name $(hostname) does not resolve; the installer connects to it over SSH"
}

check_port() {
  if ss -Hltn "sport = :${QUAY_PORT}" | grep -q .; then
    die "port ${QUAY_PORT} is already in use: $(ss -Hltnp "sport = :${QUAY_PORT}" | head -1)"
  fi
  log "port: ${QUAY_PORT} is free"
}

check_existing_install() {
  local path
  for path in "$QUAY_ROOT/quay-config" "$QUAY_STORAGE" "$SQLITE_STORAGE"; do
    if [[ -e "$path" ]] && [[ -n "$(ls -A "$path" 2>/dev/null)" ]]; then
      die "$path already has data; a registry is installed here. Use mirror-registry upgrade or uninstall instead"
    fi
  done
  if podman pod exists quay-pod 2>/dev/null; then
    die "the Podman pod quay-pod already exists; a registry is installed on this host"
  fi
}

check_tarball() {
  [[ -f "$MIRROR_REGISTRY_TARBALL" ]] || die "tarball not found: $MIRROR_REGISTRY_TARBALL"
  local listing missing=() name
  listing=$(tar -tzf "$MIRROR_REGISTRY_TARBALL") || die "cannot read: $MIRROR_REGISTRY_TARBALL"
  for name in "${INSTALLER_FILES[@]}"; do
    grep -qx -- "$name" <<<"$listing" || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "$MIRROR_REGISTRY_TARBALL lacks: ${missing[*]}"
  log "checked: $MIRROR_REGISTRY_TARBALL (sha256 $(sha256sum "$MIRROR_REGISTRY_TARBALL" | cut -d' ' -f1))"
}

report_space() {
  local parent=$REGISTRY_DATA
  while [[ ! -d "$parent" ]]; do parent=$(dirname "$parent"); done
  log "space: $(df -h --output=avail "$parent" | tail -1 | tr -d ' ') free on the file system of $REGISTRY_DATA"
}

build_command() {
  install_cmd=(./mirror-registry install
    --quayHostname "$quay_host"
    --quayRoot "$QUAY_ROOT"
    --quayStorage "$QUAY_STORAGE"
    --sqliteStorage "$SQLITE_STORAGE"
    --initUser "$INIT_USER")
  if [[ -n "$INIT_PASSWORD" ]]; then
    install_cmd+=(--initPassword "$INIT_PASSWORD")
  fi
  if [[ -n "$SSL_CERT" ]]; then
    install_cmd+=(--sslCert "$SSL_CERT" --sslKey "$SSL_KEY")
  fi
  install_cmd+=(-v)
}

# Prints the command with the password hidden.
show_command() {
  local shown=() arg hide=false
  for arg in "${install_cmd[@]}"; do
    if $hide; then shown+=("'<hidden>'"); hide=false; continue; fi
    [[ "$arg" == --initPassword ]] && hide=true
    shown+=("$(printf '%q' "$arg")")
  done
  log "command (in ${MIRROR_REGISTRY_DIR}): ${shown[*]}"
}

prepare_dirs() {
  install -d -m 0750 "$REGISTRY_DATA" "$MIRROR_REGISTRY_DIR" "$QUAY_ROOT" "$QUAY_STORAGE" "$SQLITE_STORAGE"
  log "folders: $REGISTRY_DATA with mirror-registry, quay-install, quay-storage, sqlite-storage"
}

unpack_installer() {
  tar -xzf "$MIRROR_REGISTRY_TARBALL" -C "$MIRROR_REGISTRY_DIR" -- "${INSTALLER_FILES[@]}"
  chmod 0755 "${MIRROR_REGISTRY_DIR}/mirror-registry"
  log "unpacked: $("${MIRROR_REGISTRY_DIR}/mirror-registry" --version 2>&1 | tail -1) in $MIRROR_REGISTRY_DIR"
}

# The log holds the generated password of INIT_USER, so only root can read it. Only the log gets the
# strict mode: a umask for the whole install would also apply to the files that Quay's containers read.
run_install() {
  local log_file
  log_file="${REGISTRY_DATA}/install-$(date +%Y%m%dT%H%M%S).log"
  install -m 0600 /dev/null "$log_file"
  log "installing; full output in $log_file"
  if ! (cd "$MIRROR_REGISTRY_DIR" && "${install_cmd[@]}" 2>&1 | tee -a "$log_file"); then
    die "mirror-registry install failed; read $log_file"
  fi
  log "installed. The credentials of $INIT_USER are in the last lines of $log_file"
}

verify_install() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -k "https://${quay_host}/health/instance") \
    || die "https://${quay_host}/health/instance did not answer"
  [[ "$code" == 200 ]] || die "https://${quay_host}/health/instance returned HTTP $code"
  log "health: https://${quay_host}/health/instance returned HTTP 200"
  log "log in with: podman login ${quay_host}"
}

main() {
  parse_args "$@"
  check_host
  check_inputs
  check_tarball
  check_existing_install
  check_port
  report_space
  check_name_resolution
  build_command
  show_command
  if $dry_run; then
    log "dry run: all checks passed; nothing was changed"
    return
  fi
  prepare_dirs
  unpack_installer
  run_install
  verify_install
}

main "$@"
