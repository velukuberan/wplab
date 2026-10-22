#!/usr/bin/env bash
# WPLab remote server installer.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

root=$(wplab_project_root)
config="$root/config/remote.env"

load_remote_config() {
    [[ -f "$config" && ! -L "$config" ]] ||
        wplab_fail "Missing or unsafe configuration: $config"
    [[ -O "$config" ]] ||
        wplab_fail 'Configuration must be owned by the current user'
    [[ $(stat -c '%a' "$config") == 600 ]] ||
        wplab_fail 'Configuration must have permissions 600'

    unset WPLAB_DOMAIN WPLAB_ACME_EMAIL WPLAB_DNS_PROVIDER
    # Configuration is trusted, user-owned shell code.
    source "$config"

    [[ -n ${WPLAB_DOMAIN:-} ]] || wplab_fail 'WPLAB_DOMAIN is required'
    [[ "$WPLAB_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
        wplab_fail 'Invalid WPLAB_DOMAIN'
    [[ "$WPLAB_DOMAIN" == *.* && "$WPLAB_DOMAIN" != *..* ]] ||
        wplab_fail 'WPLAB_DOMAIN must be a valid domain name'
    [[ -n ${WPLAB_ACME_EMAIL:-} ]] || wplab_fail 'WPLAB_ACME_EMAIL is required'
    [[ "$WPLAB_ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
        wplab_fail 'Invalid WPLAB_ACME_EMAIL'
    case "${WPLAB_DNS_PROVIDER:-}" in
        digitalocean) ;;
        *) wplab_fail 'Unsupported DNS provider (currently: digitalocean)' ;;
    esac
}

validate_remote_secrets() {
    local secrets="$root/config/remote.secrets.env"
    [[ -f "$secrets" && ! -L "$secrets" ]] ||
        wplab_fail "Missing or unsafe credentials file: $secrets"
    [[ -O "$secrets" ]] ||
        wplab_fail 'Credentials file must be owned by the current user'
    [[ $(stat -c '%a' "$secrets") == 600 ]] ||
        wplab_fail 'Credentials file must have permissions 600'

    (
        unset DO_AUTH_TOKEN
        source "$secrets"
        [[ -n ${DO_AUTH_TOKEN:-} ]] || wplab_fail 'DO_AUTH_TOKEN is missing or empty'
    )
    printf '  API credentials: configured (not displayed)\n'
}

check_python_dependencies() {
    command -v python3 >/dev/null 2>&1 ||
        wplab_fail 'Python 3 is required. Install python3 using your package manager.'
    python3 -c 'import yaml' >/dev/null 2>&1 ||
        wplab_fail 'PyYAML is required. On Ubuntu/Debian, install python3-yaml.'
    wplab_ok 'Python 3 available'
    wplab_ok 'PyYAML available'
}

check_auth_dependencies() {
    if ! command -v htpasswd >/dev/null 2>&1; then
        wplab_fail \
            'htpasswd is required for dashboard authentication. On Ubuntu/Debian, install apache2-utils.'
    fi

    wplab_ok 'htpasswd available'
}

check_remote_infrastructure() {
    printf '\nInfrastructure checks:\n'
    wplab_require_commands docker ss
    docker info >/dev/null 2>&1 || wplab_fail 'Docker daemon is unavailable'
    docker compose version >/dev/null 2>&1 || wplab_fail 'Docker Compose is unavailable'

    local name
    for name in wplab-traefik wplab-socket-proxy wplab-mailpit; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            printf '  WPLab container exists: %s (ownership not yet verified)\n' "$name"
        else
            printf '  WPLab container available: %s\n' "$name"
        fi
    done

    printf '\nHTTP/HTTPS listeners:\n'
    if ss -H -ltn '( sport = :80 or sport = :443 )' | grep -q .; then
        printf '  WARNING: Ports 80/443 have existing listeners\n'
        printf '  Existing services must be inspected before installation\n'
    else
        printf '  Ports 80/443 appear available\n'
    fi
}

# Single rendering implementation: validates YAML and writes only to stdout.
render_template() {
    local template="$1"
    case "$template" in
        traefik.yml|dynamic.yml) ;;
        *) wplab_fail "Unsupported template: $template" ;;
    esac

    WPLAB_DOMAIN="$WPLAB_DOMAIN" \
    WPLAB_ACME_EMAIL="$WPLAB_ACME_EMAIL" \
    WPLAB_DNS_PROVIDER="$WPLAB_DNS_PROVIDER" \
    python3 - "$root/traefik/remote/$template.tmpl" <<'PY'
import os
import sys
from string import Template
import yaml

with open(sys.argv[1], encoding="utf-8") as source:
    content = source.read()

values = {
    key: os.environ[key]
    for key in ("WPLAB_DOMAIN", "WPLAB_ACME_EMAIL", "WPLAB_DNS_PROVIDER")
}
rendered = Template(content).substitute(values)
document = yaml.safe_load(rendered)
if not isinstance(document, dict):
    raise ValueError("Rendered Traefik YAML must be a mapping")
sys.stdout.write(rendered)
PY
}

preview_remote_templates() {
    local name
    for name in traefik.yml dynamic.yml; do
        printf '\n--- %s (rendered preview) ---\n' "$name"
        render_template "$name"
    done
}

# Render and validate both files before publishing either one.
# Existing files are preserved and never overwritten.
# Called only during remote installation, never by --check.
render_remote_templates() {
    local directory="$root/traefik/remote"
    local name destination temp_dir published
    local existing=0
    local -a names=(traefik.yml dynamic.yml)
    local -a published_names=()

    check_python_dependencies

    # Check templates and reject symlinked runtime files.
    for name in "${names[@]}"; do
        [[ -f "$directory/$name.tmpl" && ! -L "$directory/$name.tmpl" ]] ||
            wplab_fail "Missing or unsafe template: $directory/$name.tmpl"

        destination="$directory/$name"

        [[ ! -L "$destination" ]] ||
            wplab_fail "Unsafe runtime configuration symlink: $destination"

        if [[ -e "$destination" ]]; then
            [[ -f "$destination" && -O "$destination" ]] ||
                wplab_fail "Unmanaged runtime configuration: $destination"
            ((existing += 1))
        fi
    done

    # Reject partial installations.
    if (( existing == 1 )); then
        wplab_fail 'Partial runtime configuration detected; manual inspection required'
    fi

    temp_dir=$(mktemp -d "$directory/.render.XXXXXXXX") ||
        wplab_fail 'Cannot create staging directory'

    # Render and validate BOTH files before publishing either.
    for name in "${names[@]}"; do
        if ! render_template "$name" > "$temp_dir/$name"; then
            rm -rf -- "$temp_dir"
            wplab_fail "Failed to render $name; no files published"
        fi

        chmod 600 "$temp_dir/$name"
    done

    # Repeated installation: preserve existing, identical files.
    if (( existing == 2 )); then
        for name in "${names[@]}"; do
            destination="$directory/$name"

            if ! cmp -s "$temp_dir/$name" "$destination"; then
                rm -rf -- "$temp_dir"
                wplab_fail \
                    "Existing configuration differs from template: $destination"
            fi
        done

        rm -rf -- "$temp_dir"
        wplab_ok 'Existing remote configuration matches templates; preserved'
        return 0
    fi

    # First installation: publish only if all destinations remain absent.
    for name in "${names[@]}"; do
        destination="$directory/$name"

        if [[ -e "$destination" || -L "$destination" ]]; then
            rm -rf -- "$temp_dir"
            wplab_fail "Destination appeared during rendering: $destination"
        fi
    done

    for name in "${names[@]}"; do
        destination="$directory/$name"

        if ! ln -- "$temp_dir/$name" "$destination"; then
            for published in "${published_names[@]}"; do
                rm -f -- "$directory/$published"
            done

            rm -rf -- "$temp_dir"
            wplab_fail "Failed publishing $name; rolled back"
        fi

        published_names+=("$name")
    done

    rm -rf -- "$temp_dir"
    wplab_ok 'Remote Traefik configuration generated successfully'
}

validate_container_ownership() {
    local name expected_project actual_project

    printf '\nContainer ownership checks:\n'

    while read -r name expected_project; do
        if ! docker container inspect "$name" >/dev/null 2>&1; then
            printf '  AVAILABLE: %s\n' "$name"
            continue
        fi

        actual_project=$(docker inspect "$name" \
            --format '{{ index .Config.Labels "com.docker.compose.project" }}')

        if [[ "$actual_project" != "$expected_project" ]]; then
            wplab_fail \
                "Container '$name' belongs to '$actual_project', expected '$expected_project'. Refusing installation."
        fi

        printf '  OWNED: %s (%s)\n' "$name" "$actual_project"
    done <<'CONTAINERS'
wplab-traefik wplab-remote-traefik
wplab-socket-proxy wplab-remote-traefik
wplab-mailpit wplab-remote-mailpit
CONTAINERS
}

validate_remote_ports() {
    local listeners

    wplab_require_commands ss

    listeners=$(ss -H -ltn '( sport = :80 or sport = :443 )')

    if [[ -n "$listeners" ]]; then
        wplab_fail \
            'Ports 80/443 are occupied. Stop conflicting services explicitly before installing WPLab.'
    fi

    wplab_ok 'Ports 80/443 are available'
}

prepare_acme_storage() {
    local directory="$root/traefik/remote/letsencrypt"
    local storage="$directory/acme.json"

    wplab_require_commands install stat

    # Reject symlinks rather than following unexpected paths.
    [[ ! -L "$directory" && ! -L "$storage" ]] ||
        wplab_fail 'Unsafe ACME storage symlink detected'

    install -d -m 700 "$directory"

    # Create only when absent. Never overwrite existing certificates.
    if [[ ! -e "$storage" ]]; then
        install -m 600 /dev/null "$storage"
        wplab_ok 'Created ACME certificate storage'
    else
        [[ -f "$storage" ]] ||
            wplab_fail 'ACME storage is not a regular file'

        wplab_ok 'Preserving existing ACME certificate storage'
    fi

    [[ "$(stat -c '%a' "$storage")" == 600 ]] ||
        wplab_fail 'ACME storage must have permissions 600'
}

acquire_install_lock() {
    local lock_dir="$HOME/.config/wplab"
    local lock_file="$lock_dir/install.lock"

    wplab_require_commands flock

    # Ensure the lock directory is private.
    [[ ! -L "$lock_dir" ]] ||
        wplab_fail "Unsafe lock directory: $lock_dir"

    if [[ -e "$lock_dir" ]]; then
        [[ -d "$lock_dir" && -O "$lock_dir" ]] ||
            wplab_fail "Lock directory has unexpected ownership or type"
    else
        install -d -m 700 "$lock_dir"
    fi

    # Refuse unexpected symlinks or file types.
    [[ ! -L "$lock_file" ]] ||
        wplab_fail "Unsafe lock file: $lock_file"

    if [[ -e "$lock_file" ]]; then
        [[ -f "$lock_file" && -O "$lock_file" ]] ||
            wplab_fail "Lock file has unexpected ownership or type"
    fi

    # File descriptor 9 remains open until the installer exits.
    (
        umask 077
        : >> "$lock_file"
    )

    exec 9>>"$lock_file"

    flock -n 9 ||
        wplab_fail 'Another WPLab installation is already running'

    wplab_ok 'Installation lock acquired'
}

configure_runtime_identity() {
    WPLAB_UID="$(id -u)" ||
        wplab_fail 'Unable to determine the installation user UID'

    WPLAB_GID="$(id -g)" ||
        wplab_fail 'Unable to determine the installation user GID'

    [[ "$WPLAB_UID" =~ ^[0-9]+$ ]] ||
        wplab_fail 'Invalid WPLAB_UID'

    [[ "$WPLAB_GID" =~ ^[0-9]+$ ]] ||
        wplab_fail 'Invalid WPLAB_GID'

    [[ "$WPLAB_UID" -ne 0 ]] ||
        wplab_fail 'Remote installation must run as a non-root user'

    export WPLAB_UID WPLAB_GID

    wplab_ok "Runtime identity configured (UID=$WPLAB_UID, GID=$WPLAB_GID)"
}

validate_remote_compose() {
    local project_root
    project_root="$(wplab_project_root)"

    local compose_file="$project_root/traefik/remote/docker-compose.yml"
    local secrets_file="$project_root/config/remote.secrets.env"

    [[ -f "$compose_file" ]] ||
        wplab_fail "Remote Docker Compose file missing: $compose_file"

    [[ -n "${WPLAB_UID:-}" && -n "${WPLAB_GID:-}" ]] ||
        wplab_fail 'Runtime identity has not been configured'

    docker compose \
        --env-file "$secrets_file" \
        -f "$compose_file" \
        config --quiet ||
        wplab_fail 'Remote Docker Compose configuration is invalid'

    wplab_ok 'Remote Docker Compose configuration is valid'
}

preflight_remote() {
    load_remote_config
    wplab_validate_environment remote "$WPLAB_DOMAIN"
    validate_remote_secrets
    check_python_dependencies
    check_auth_dependencies
    check_remote_infrastructure
    validate_container_ownership
}

check_remote() {
    preflight_remote
    wplab_info 'WPLab remote configuration'
    printf '  Domain:       %s\n' "$WPLAB_DOMAIN"
    printf '  ACME email:   %s\n' "$WPLAB_ACME_EMAIL"
    printf '  DNS provider: %s\n' "$WPLAB_DNS_PROVIDER"
    preview_remote_templates
    wplab_info 'Diagnostics complete. No changes made.'
}

case "${1:-}" in
    --check)
        check_remote
        ;;
    '')
        acquire_install_lock

        # Installation is deliberately disabled while the preflight still only
        # warns about port conflicts and container ownership is not enforced.
        preflight_remote
        validate_remote_ports

        # Determine the user that will run Traefik.
        configure_runtime_identity

        # Validate Compose before modifying runtime files.
        validate_remote_compose

        # Render and validate both Traefik configuration files.
        render_remote_templates

        # Only execute after all safety checks pass.
        prepare_acme_storage

        wplab_fail 'Remote installation is not implemented yet. No changes made.'
        ;;
    *)
        wplab_fail "Unsupported remote installer argument: $1"
        ;;
esac

