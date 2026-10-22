#!/usr/bin/env bash
# WPLab local workstation installer (safe to rerun).
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '▶ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }

case "${1:-}" in
    --check|--setup-dns|--remove-dns)
        root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
        exec bash "$root/bin/wplab-dns" "$1"
        ;;
    '') ;;
    *) fail 'Usage: ./install.sh [--check|--setup-dns|--remove-dns]' ;;
esac

[[ ${EUID} -ne 0 ]] || fail 'Run as your normal user, not root/sudo'
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
[[ -f "$root/traefik/docker-compose.yml" && -f "$root/mailpit/docker-compose.yml" ]] || fail 'Run the installer from a complete WPLab checkout'
for cmd in docker jq python3 flock realpath; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing prerequisite: $cmd"
done
docker compose version >/dev/null 2>&1 || fail 'Docker Compose plugin is required'
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable to this user'

# Traefik loads the local wildcard certificate from these paths.
cert_dir="$root/traefik/certs"
cert="$cert_dir/wplab.test.pem"
key="$cert_dir/wplab.test-key.pem"
if [[ -s "$cert" && -s "$key" ]]; then
    ok 'Using existing WPLab TLS certificate and key'
elif [[ -e "$cert" || -e "$key" || -L "$cert" || -L "$key" ]]; then
    fail 'TLS certificate/key pair is incomplete or empty; refusing to overwrite. Repair or back up the existing files manually.'
else
    command -v mkcert >/dev/null 2>&1 ||
        fail 'mkcert is required for first-time TLS setup. Install mkcert and its NSS dependencies, then rerun.'
    info 'Installing mkcert local development CA into the user/system trust stores'
    mkcert -install || fail 'mkcert trust-store installation failed'
    mkdir -p -- "$cert_dir"
    chmod 700 "$cert_dir"
    info 'Generating local wildcard TLS certificate for wplab.test'
    # Generate into temporary names; publish only when both files exist.
    cert_tmp=$(mktemp "$cert_dir/.wplab-cert.XXXXXXXX") || fail 'Cannot prepare certificate'
    key_tmp=$(mktemp "$cert_dir/.wplab-key.XXXXXXXX") || fail 'Cannot prepare private key'
    cleanup_tls() { rm -f -- "$cert_tmp" "$key_tmp"; }
    trap cleanup_tls EXIT
    mkcert -cert-file "$cert_tmp" -key-file "$key_tmp" \
        wplab.test '*.wplab.test' || fail 'mkcert certificate generation failed'
    [[ -s "$cert_tmp" && -s "$key_tmp" ]] || fail 'mkcert generated empty certificate/key'
    chmod 644 "$cert_tmp"
    chmod 600 "$key_tmp"
    mv -n -- "$cert_tmp" "$cert" || fail 'Could not install TLS certificate'
    mv -n -- "$key_tmp" "$key" || fail 'Could not install TLS private key'
    [[ -s "$cert" && -s "$key" ]] || fail 'TLS certificate installation incomplete'
    trap - EXIT
    ok 'Local HTTPS certificate generated'
fi

bin_dir=${WPLAB_BIN_DIR:-"$HOME/.local/bin"}
[[ "$bin_dir" == /* ]] || fail 'WPLAB_BIN_DIR must be an absolute path'
[[ ! -L "$bin_dir" ]] || fail 'Refusing a symlinked CLI directory'
for name in newsite siteinfo killsite; do
    target="$root/bin/$name"
    [[ -f "$target" && -x "$target" ]] || fail "Missing executable: $target"
    if [[ -e "$bin_dir/$name" || -L "$bin_dir/$name" ]]; then
        [[ -L "$bin_dir/$name" && "$(readlink -- "$bin_dir/$name")" == "$target" ]] ||
            fail "Existing '$bin_dir/$name' is not WPLab's symlink; refusing to overwrite"
    fi
done

info 'Creating shared external Docker networks (if missing)'
for network in web wplab-mail; do
    if ! docker network inspect "$network" >/dev/null 2>&1; then
        docker network create "$network" >/dev/null
        ok "Created network: $network"
    else
        ok "Using existing network: $network"
    fi
done

info 'Validating shared Compose configurations'
docker compose -f "$root/traefik/docker-compose.yml" config --quiet
docker compose -f "$root/mailpit/docker-compose.yml" config --quiet

info 'Starting Traefik and Mailpit without removing existing volumes'
docker compose -f "$root/traefik/docker-compose.yml" up -d
docker compose -f "$root/mailpit/docker-compose.yml" up -d

info "Installing CLI symlinks in $bin_dir"
mkdir -p -- "$bin_dir"
for name in newsite siteinfo killsite; do
    ln -s -- "$root/bin/$name" "$bin_dir/$name" 2>/dev/null || {
        [[ -L "$bin_dir/$name" && "$(readlink -- "$bin_dir/$name")" == "$root/bin/$name" ]] || fail "Cannot install $name"
    }
    ok "$name"
done

printf '\nWPLab infrastructure installed.\n'
printf 'Mailpit: https://mail.wplab.test\n'
printf 'CLI directory: %s\n' "$bin_dir"
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) printf 'NOTE: Add %s to your PATH to run newsite/siteinfo/killsite globally.\n' "$bin_dir" ;;
esac
printf 'NOTE: Your DNS/hosts resolver must map *.wplab.test to local Traefik.\n'
