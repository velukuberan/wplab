#!/usr/bin/env bash
# WPLab remote server installer.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

root=$(wplab_project_root)
config="$root/config/remote.env"
# Remote deployment is disabled until the complete lifecycle is verified.
WPLAB_REMOTE_DEPLOYMENT_ENABLED=false

# Load only explicitly supported remote DNS providers.
load_dns_provider() {
    local provider="${WPLAB_DNS_PROVIDER:-}"
    local module

    case "$provider" in
        digitalocean)
            module="$root/installers/providers/digitalocean.sh"
            ;;
        *)
            wplab_fail "Unsupported DNS provider (currently: digitalocean)"
            ;;
    esac

    [[ -f "$module" && ! -L "$module" ]] ||
        wplab_fail "Missing or unsafe DNS provider module: $module"

    # Provider modules are trusted code shipped with WPLab.
    source "$module"
}

remote_provider_compose_file() {
    case "${WPLAB_DNS_PROVIDER:-}" in
        digitalocean)
            printf '%s\n' \
                "$root/traefik/remote/providers/digitalocean.compose.yml"
            ;;
        *)
            wplab_fail 'Unsupported DNS provider'
            ;;
    esac
}

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
    load_dns_provider
    provider_validate_config
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
        provider_validate_secrets
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
    WPLAB_DNS_PROVIDER="$(provider_acme_name)" \
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
        # Record immediately after publication for outer transaction rollback.
        if [[ "${WPLAB_ROLLBACK_ARMED:-false}" == true ]]; then
            record_remote_file "$destination"
        fi
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

    if [[ -e "$directory" ]]; then
        [[ -d "$directory" && -O "$directory" ]] ||
            wplab_fail 'ACME directory has unexpected ownership or type'

        [[ "$(stat -c '%a' "$directory")" == 700 ]] ||
            wplab_fail 'Existing ACME directory must have permissions 700'
    else
        install -d -m 700 "$directory" ||
            wplab_fail 'Unable to create ACME directory'
    fi

    # Create only when absent. Never overwrite existing certificates.
    if [[ ! -e "$storage" ]]; then
        install -m 600 /dev/null "$storage"
        wplab_ok 'Created ACME certificate storage'
    else
        [[ -f "$storage" ]] ||
            wplab_fail 'ACME storage is not a regular file'

        wplab_ok 'Preserving existing ACME certificate storage'
    fi

    [[ -O "$directory" && -O "$storage" ]] ||
        wplab_fail 'ACME storage must be owned by the installation user'

    [[ "$(stat -c '%a' "$directory")" == 700 ]] ||
        wplab_fail 'ACME directory must have permissions 700'

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

validate_remote_networks() {
    local network driver internal

    printf '\nShared Docker network checks:\n'

    for network in web wplab-mail; do
        if ! docker network inspect "$network" >/dev/null 2>&1; then
            printf '  MISSING: %s (will require creation)\n' "$network"
            continue
        fi

        driver=$(docker network inspect "$network" \
            --format '{{.Driver}}')

        internal=$(docker network inspect "$network" \
            --format '{{.Internal}}')

        [[ "$driver" == "bridge" ]] ||
            wplab_fail "Network '$network' must use the bridge driver"

        [[ "$internal" == "false" ]] ||
            wplab_fail "Network '$network' is unexpectedly internal"

        printf '  VALID: %s (existing bridge network)\n' "$network"
    done
}

# Networks created during the current installation.
# Used later for controlled rollback.
WPLAB_CREATED_NETWORKS=()
WPLAB_CREATED_NETWORK_IDS=()

prepare_remote_networks() {
    local network network_list

    # Revalidate before making changes.
    validate_remote_networks

    for network in web wplab-mail; do
        if docker network inspect "$network" >/dev/null 2>&1; then
            wplab_ok "Preserving existing Docker network: $network"
            continue
        fi

        # Confirm Docker is responsive before treating the network as missing.
        docker info >/dev/null 2>&1 ||
            wplab_fail 'Docker daemon is unavailable during network preparation'

        # Inspect network names through an independent Docker query.
        network_list=$(docker network ls --format '{{.Name}}') ||
            wplab_fail 'Unable to list Docker networks'

        if grep -Fxq -- "$network" <<< "$network_list"; then
            wplab_fail "Network '$network' exists but inspection failed"
        fi

        # Docker returns the created network ID directly.
        # Capture it before performing any further operations.
        local network_id
        network_id=$(docker network create \
            --driver bridge \
            "$network") ||
            wplab_fail "Unable to create Docker network: $network"

        [[ -n "$network_id" ]] ||
            wplab_fail "Docker returned no ID for created network: $network"

        WPLAB_CREATED_NETWORKS+=("$network")
        WPLAB_CREATED_NETWORK_IDS+=("$network_id")

        wplab_ok "Created Docker network: $network"
    done

    # Confirm the resulting networks meet our requirements.
    validate_remote_networks
}

# Compose creates its private socket network implicitly. Only a network observed
# absent before startup and identified by Docker labels may be rolled back.
WPLAB_COMPOSE_SOCKET_WAS_ABSENT=false
WPLAB_COMPOSE_SOCKET_ID=""

check_compose_socket_absent() {
    local name=wplab-remote-traefik_socket
    WPLAB_COMPOSE_SOCKET_WAS_ABSENT=false
    if docker network inspect "$name" >/dev/null 2>&1; then
        wplab_fail "Existing Compose socket network requires manual review: $name"
    fi
    WPLAB_COMPOSE_SOCKET_WAS_ABSENT=true
}

track_compose_socket_network() {
    local name=wplab-remote-traefik_socket identity
    [[ "$WPLAB_COMPOSE_SOCKET_WAS_ABSENT" == true ]] || return 0
    identity=$(docker network inspect "$name" --format \
        '{{.Id}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.docker.compose.network"}}' 2>/dev/null) || return 0
    case "$identity" in
        *'|wplab-remote-traefik|socket')
            WPLAB_COMPOSE_SOCKET_ID="${identity%%|*}"
            ;;
        *) wplab_info "Unverified Compose socket network; preserving: $name" ;;
    esac
}

rollback_compose_socket_network() {
    local name=wplab-remote-traefik_socket identity count
    [[ -n "$WPLAB_COMPOSE_SOCKET_ID" ]] || return 0
    identity=$(docker network inspect "$name" --format \
        '{{.Id}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.docker.compose.network"}}' 2>/dev/null) || return 0
    [[ "$identity" == "$WPLAB_COMPOSE_SOCKET_ID|wplab-remote-traefik|socket" ]] || {
        wplab_info 'Preserving changed Compose socket network'
        return 0
    }
    count=$(docker network inspect "$name" --format '{{len .Containers}}') || return 0
    [[ "$count" == 0 ]] || {
        wplab_info 'Preserving Compose socket network with attached containers'
        return 0
    }
    docker network rm "$WPLAB_COMPOSE_SOCKET_ID" >/dev/null ||
        wplab_info 'Compose socket network requires manual cleanup'
}

# A Mailpit data volume is persistent data, never a rollback target.
report_mailpit_volume() {
    local volume=wplab-remote-mailpit_mailpit_data project
    project=$(docker volume inspect "$volume" --format \
        '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null) || return 0
    if [[ "$project" == wplab-remote-mailpit ]]; then
        wplab_info "Preserving persistent Mailpit volume: $volume"
    fi
}

# Recovery is intentionally limited to the observed interrupted-install case:
# only a private ACME directory with a valid existing ACME JSON file remains.
# Other partial states require manual investigation, not automatic adoption.
validate_acme_only_recovery() {
    local runtime="$root/traefik/remote" path
    [[ "$WPLAB_INSTALL_STATE" == partial ]] ||
        wplab_fail 'Recovery requires a partial installation'
    [[ ! -e "$HOME/.config/wplab/environment.env" &&
       ! -L "$HOME/.config/wplab/environment.env" ]] ||
        wplab_fail 'Recovery refuses an existing installation identity'
    for path in traefik.yml dynamic.yml dashboard-users; do
        [[ ! -e "$runtime/$path" && ! -L "$runtime/$path" ]] ||
            wplab_fail "Recovery refuses existing runtime configuration: $path"
    done
    [[ -d "$runtime/letsencrypt" && ! -L "$runtime/letsencrypt" &&
       -O "$runtime/letsencrypt" ]] || wplab_fail 'Unsafe ACME directory for recovery'
    [[ $(stat -c '%a' "$runtime/letsencrypt") == 700 ]] ||
        wplab_fail 'Recovery ACME directory requires permissions 700'
    # Reject unexpected sibling resources; this is not a general repair tool.
    local entry
    shopt -s nullglob dotglob
    for entry in "$runtime/letsencrypt"/*; do
        [[ "$entry" == "$runtime/letsencrypt/acme.json" ]] ||
            wplab_fail "Unexpected recovery ACME resource: $entry"
    done
    shopt -u nullglob dotglob
    path="$runtime/letsencrypt/acme.json"
    [[ -f "$path" && ! -L "$path" && -O "$path" && -s "$path" ]] ||
        wplab_fail 'Recovery requires an owned, nonempty ACME file'
    [[ $(stat -c '%a' "$path") == 600 ]] ||
        wplab_fail 'Recovery ACME file requires permissions 600'
    # Fail closed on malformed JSON or unexpected resolver structure.
    python3 - "$path" <<'PYACME' || wplab_fail 'Unsafe ACME JSON for recovery'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
assert isinstance(data, dict) and isinstance(data.get('dnsresolver'), dict)
assert isinstance(data['dnsresolver'].get('Account'), dict)
PYACME
    wplab_ok 'Preserved ACME account verified for explicit recovery'
}

rollback_remote_networks() {
    local index network expected_id current_id container_count

    for ((index=${#WPLAB_CREATED_NETWORKS[@]}-1; index>=0; index--)); do
        network="${WPLAB_CREATED_NETWORKS[$index]}"
        expected_id="${WPLAB_CREATED_NETWORK_IDS[$index]:-}"

        [[ -n "$expected_id" ]] || {
            wplab_info "Skipping rollback: network '$network' has no recorded ID"
            continue
        }

        # Never delete the shared ingress network.
        [[ "$network" != "web" ]] || continue

        current_id=$(docker network inspect "$network" \
            --format '{{.Id}}') || {
            wplab_info "Skipping rollback: cannot inspect network '$network'"
            continue
        }

        if [[ "$current_id" != "$expected_id" ]]; then
            wplab_info "Skipping rollback: network '$network' identity changed"
            continue
        fi

        container_count=$(docker network inspect "$network" \
            --format '{{len .Containers}}') || {
            wplab_info "Skipping rollback: cannot inspect containers on '$network'"
            continue
        }

        if [[ "$container_count" != "0" ]]; then
            wplab_info "Skipping rollback: network '$network' has attached containers"
            continue
        fi

        if docker network rm "$expected_id" >/dev/null; then
            wplab_ok "Rolled back Docker network: $network"
        else
            wplab_info "Could not roll back Docker network: $network"
        fi
    done
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

    local provider_compose
    provider_compose=$(remote_provider_compose_file)

    [[ -f "$provider_compose" && ! -L "$provider_compose" ]] ||
        wplab_fail "Missing or unsafe provider Compose file: $provider_compose"

    docker compose \
        --env-file "$secrets_file" \
        -f "$compose_file" \
        -f "$provider_compose" \
        config --quiet ||
        wplab_fail 'Remote Docker Compose configuration is invalid'

    wplab_ok 'Remote Docker Compose configuration is valid'
}

validate_remote_mailpit_compose() {
    local compose_file="$root/mailpit/remote/docker-compose.yml"

    [[ -f "$compose_file" && ! -L "$compose_file" ]] ||
        wplab_fail "Remote Mailpit Compose file missing or unsafe: $compose_file"

    [[ -n "${WPLAB_DOMAIN:-}" ]] ||
        wplab_fail 'WPLAB_DOMAIN is required for remote Mailpit'

    WPLAB_DOMAIN="$WPLAB_DOMAIN" \
        docker compose \
        -f "$compose_file" \
        config --quiet ||
        wplab_fail 'Remote Mailpit Compose configuration is invalid'

    wplab_ok 'Remote Mailpit Compose configuration is valid'
}

detect_remote_installation_state() {
    local identity="$HOME/.config/wplab/environment.env"
    local runtime="$root/traefik/remote"
    local resource
    local -a resources=(
        "$runtime/traefik.yml"
        "$runtime/dynamic.yml"
        "$runtime/letsencrypt"
        "$runtime/letsencrypt/acme.json"
        "$runtime/dashboard-users"
    )

    if [[ -e "$identity" || -L "$identity" ]]; then
        # An installation identity alone does not prove
        # that the installation completed successfully.
        for resource in "${resources[@]}"; do
            if [[ ! -e "$resource" || -L "$resource" ]]; then
                WPLAB_INSTALL_STATE="partial"
                wplab_info "Incomplete WPLab installation: $resource"
                return 0
            fi
        done

        # Validate resource types before classifying as existing.
        if [[ ! -f "$identity" || -L "$identity" ||
              ! -d "$runtime/letsencrypt" || -L "$runtime/letsencrypt" ]]; then
            WPLAB_INSTALL_STATE="partial"
            wplab_info "Unsafe installation identity or ACME directory"
            return 0
        fi

        for resource in \
            "$runtime/traefik.yml" \
            "$runtime/dynamic.yml" \
            "$runtime/letsencrypt/acme.json" \
            "$runtime/dashboard-users"; do

            if [[ ! -f "$resource" || -L "$resource" ]]; then
                WPLAB_INSTALL_STATE="partial"
                wplab_info "Unexpected installation resource type: $resource"
                return 0
            fi
        done

        # An existing installation must have a valid identity.
        # Reject malformed, incorrectly owned, or conflicting configurations.
        # Validate ownership and permissions of runtime resources.
        [[ -O "$runtime/letsencrypt" ]] ||
            wplab_fail 'ACME directory has unexpected ownership'

        [[ "$(stat -c '%a' "$runtime/letsencrypt")" == 700 ]] ||
            wplab_fail 'ACME directory must have permissions 700'

        for resource in \
            "$runtime/traefik.yml" \
            "$runtime/dynamic.yml" \
            "$runtime/letsencrypt/acme.json" \
            "$runtime/dashboard-users"; do

            [[ -O "$resource" ]] ||
                wplab_fail "Unexpected runtime file ownership: $resource"

            [[ "$(stat -c '%a' "$resource")" == 600 ]] ||
                wplab_fail "Runtime file must have permissions 600: $resource"
        done

        WPLAB_INSTALL_STATE="existing"
        wplab_info "Existing WPLab installation files and identity verified"
        return 0
    fi

    for resource in "${resources[@]}"; do
        if [[ -e "$resource" || -L "$resource" ]]; then
            WPLAB_INSTALL_STATE="partial"
            wplab_info "Partial WPLab installation detected: $resource"
            return 0
        fi
    done

    WPLAB_INSTALL_STATE="fresh"
    wplab_ok "Fresh WPLab installation detected"
}

preflight_remote() {
    load_remote_config
    wplab_validate_environment remote "$WPLAB_DOMAIN"
    detect_remote_installation_state
    validate_remote_secrets
    check_python_dependencies
    check_auth_dependencies
    check_remote_infrastructure
    validate_container_ownership
    validate_remote_networks
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

# WPLAB_TRANSACTION_V1 — candidate remote install transaction.
# These arrays only track resources created by THIS installer process.
WPLAB_CREATED_FILES=()
WPLAB_CREATED_FILE_INODES=()
# Only IDs observed immediately after our own Compose startup are rollback-eligible.
WPLAB_CREATED_CONTAINER_IDS=()
WPLAB_CREATED_CONTAINER_NAMES=()

record_remote_file() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" && -O "$file" ]] ||
        wplab_fail "Cannot record unowned runtime file: $file"
    local inode
    inode=$(stat -c '%d:%i' -- "$file") || wplab_fail "Cannot identify file: $file"
    WPLAB_CREATED_FILES+=("$file")
    WPLAB_CREATED_FILE_INODES+=("$inode")
}

# Never replace the user's dashboard password or accept a pre-existing auth file.
create_remote_dashboard_auth() {
    local path="$root/traefik/remote/dashboard-users"
    local password confirm tmp
    [[ ! -e "$path" && ! -L "$path" ]] ||
        wplab_fail "Dashboard credentials already exist: $path"
    [[ -t 0 ]] || wplab_fail 'Interactive terminal required for new dashboard password'
    read -r -s -p 'WPLab dashboard password: ' password
    printf '\n'
    read -r -s -p 'Confirm dashboard password: ' confirm
    printf '\n'
    [[ -n "$password" && "$password" == "$confirm" ]] ||
        wplab_fail 'Dashboard password missing or confirmation does not match'
    [[ ${#password} -ge 12 ]] || wplab_fail 'Dashboard password must have at least 12 characters'
    tmp=$(mktemp "$root/traefik/remote/.dashboard-users.XXXXXXXX") ||
        wplab_fail 'Unable to stage dashboard authentication'
    chmod 600 "$tmp"
    # Feed the password over stdin (never as a command-line argument).
    if ! printf '%s\n' "$password" | htpasswd -nBi admin > "$tmp"; then
        rm -f -- "$tmp"
        wplab_fail 'Unable to generate dashboard bcrypt credentials'
    fi
    unset password confirm
    if ! ln -- "$tmp" "$path"; then
        rm -f -- "$tmp"
        wplab_fail 'Cannot publish dashboard authentication without overwrite'
    fi
    record_remote_file "$path"
    rm -f -- "$tmp"
    wplab_ok 'Dashboard authentication created'
}

validate_fresh_container_absence() {
    local name
    for name in wplab-traefik wplab-socket-proxy wplab-mailpit; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            wplab_fail "Fresh installation cannot adopt existing container: $name"
        fi
    done
}

# Compare container name AND project/service labels, plus the WPLab-specific
# management label. An unrelated container must never be removed.
remote_container_owned() {
    local name="$1" expected_project="$2" expected_service="$3" labels
    labels=$(docker container inspect "$name" --format \
        '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "wplab.managed"}}' 2>/dev/null) || return 1
    [[ "$labels" == "$expected_project|$expected_service|true" ]]
}

# Capture IDs immediately after a Compose invocation, including a failed one.
# A concurrent actor can still race with creation; unknown IDs are left intact.
track_remote_containers() {
    local name project service id
    while read -r name project service; do
        remote_container_owned "$name" "$project" "$service" || continue
        id=$(docker container inspect "$name" --format '{{.Id}}' 2>/dev/null) || continue
        [[ -n "$id" ]] || continue
        WPLAB_CREATED_CONTAINER_NAMES+=("$name")
        WPLAB_CREATED_CONTAINER_IDS+=("$id")
    done
}

rollback_remote_containers() {
    local index name id current_id project service
    for ((index=${#WPLAB_CREATED_CONTAINER_IDS[@]}-1; index>=0; index--)); do
        name="${WPLAB_CREATED_CONTAINER_NAMES[$index]}"
        id="${WPLAB_CREATED_CONTAINER_IDS[$index]}"
        case "$name" in
            wplab-mailpit) project=wplab-remote-mailpit; service=mailpit ;;
            wplab-traefik) project=wplab-remote-traefik; service=traefik ;;
            wplab-socket-proxy) project=wplab-remote-traefik; service=socket-proxy ;;
            *) continue ;;
        esac
        current_id=$(docker container inspect "$name" --format '{{.Id}}' 2>/dev/null) || continue
        if [[ "$current_id" != "$id" ]] ||
           ! remote_container_owned "$name" "$project" "$service"; then
            wplab_info "Preserving changed or unverified container: $name"
            continue
        fi
        docker container rm -f "$id" >/dev/null ||
            wplab_info "Manual cleanup may be required for container: $name"
    done
}

rollback_remote_files() {
    local i path expected inode
    for ((i=${#WPLAB_CREATED_FILES[@]}-1; i>=0; i--)); do
        path="${WPLAB_CREATED_FILES[$i]}"
        expected="${WPLAB_CREATED_FILE_INODES[$i]}"
        if [[ ! -f "$path" || -L "$path" || ! -O "$path" ]]; then
            wplab_info "Preserving changed runtime path: $path"
            continue
        fi
        inode=$(stat -c '%d:%i' -- "$path") || continue
        [[ "$inode" == "$expected" ]] || {
            wplab_info "Preserving changed runtime inode: $path"
            continue
        }
        # Never delete certificate data after Traefik has written to it.
        if [[ "$path" == */acme.json && -s "$path" ]]; then
            wplab_info "Preserving nonempty ACME certificate store: $path"
            continue
        fi
        rm -f -- "$path" || wplab_info "Unable to roll back runtime file: $path"
    done
    local directory="$root/traefik/remote/letsencrypt"
    # rmdir only removes a directory if empty; existing folders are untouched.
    if [[ "${WPLAB_CREATED_ACME_DIRECTORY:-false}" == true && -d "$directory" && ! -L "$directory" && -O "$directory" ]]; then
        rmdir -- "$directory" 2>/dev/null || :
    fi
}

start_remote_infrastructure() {
    local tfile="$root/traefik/remote/docker-compose.yml"
    local mfile="$root/mailpit/remote/docker-compose.yml"
    local secrets="$root/config/remote.secrets.env"
    local result=0

    check_compose_socket_absent

    # Capture created IDs on both success and failure. Never adopt a
    # pre-existing named container (validated before mutation).

    local provider_compose
    provider_compose=$(remote_provider_compose_file)

    docker compose \
        --env-file "$secrets" \
        -f "$tfile" \
        -f "$provider_compose" \
        up -d || result=$?

    track_compose_socket_network
    track_remote_containers <<'TRAEFIK_CONTAINERS'
wplab-socket-proxy wplab-remote-traefik socket-proxy
wplab-traefik wplab-remote-traefik traefik
TRAEFIK_CONTAINERS
    [[ "$result" == 0 ]] ||
        wplab_fail 'Failed starting WPLab Traefik infrastructure'

    result=0
    WPLAB_DOMAIN="$WPLAB_DOMAIN" docker compose -f "$mfile" up -d || result=$?
    track_remote_containers <<'MAILPIT_CONTAINERS'
wplab-mailpit wplab-remote-mailpit mailpit
MAILPIT_CONTAINERS
    report_mailpit_volume
    [[ "$result" == 0 ]] ||
        wplab_fail 'Failed starting WPLab Mailpit infrastructure'
}

# Docker image/Compose health checks provide the application-level readiness
# signal. Socket proxy has no health check; Traefik's Docker-provider health
# is not independently proven by the Traefik ping endpoint.
verify_remote_containers() {
    local name project service status health attempt
    local max_attempts=12

    while read -r name project service; do
        remote_container_owned "$name" "$project" "$service" ||
            wplab_fail "WPLab container ownership verification failed: $name"
        status=$(docker container inspect "$name" --format '{{.State.Running}}') ||
            wplab_fail "Cannot inspect WPLab container: $name"
        [[ "$status" == true ]] || wplab_fail "WPLab container is not running: $name"

        # Socket-proxy currently has no Docker health check.
        [[ "$service" != socket-proxy ]] || continue

        for ((attempt=1; attempt<=max_attempts; attempt++)); do
            # If the service stops while warming up, abort immediately.
            status=$(docker container inspect "$name" --format '{{.State.Running}}') ||
                wplab_fail "Cannot re-inspect WPLab container: $name"
            [[ "$status" == true ]] ||
                wplab_fail "WPLab container stopped during readiness: $name"

            health=$(docker container inspect "$name" --format \
                '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}') ||
                wplab_fail "Cannot inspect WPLab health status: $name"
            case "$health" in
                healthy)
                    wplab_ok "WPLab service healthy: $name"
                    break
                    ;;
                starting|unhealthy)
                    if (( attempt == max_attempts )); then
                        wplab_fail "WPLab service not healthy ($health): $name"
                    fi
                    ;;
                none)
                    wplab_fail "WPLab service has no health check: $name"
                    ;;
                *)
                    wplab_fail "Unexpected health status '$health': $name"
                    ;;
            esac
            sleep 5
        done
    done <<'WPLAB_CONTAINERS'
wplab-traefik wplab-remote-traefik traefik
wplab-socket-proxy wplab-remote-traefik socket-proxy
wplab-mailpit wplab-remote-mailpit mailpit
WPLAB_CONTAINERS
    wplab_ok 'Remote infrastructure running; Traefik and Mailpit healthy'
}

# Installation rollback is armed only after preflight succeeds.
WPLAB_ROLLBACK_ARMED=false

remote_install_exit_handler() {
    local exit_status=$?

    trap - EXIT

    if [[ "$WPLAB_ROLLBACK_ARMED" == "true" &&
          "$exit_status" -ne 0 ]]; then
        wplab_info 'Remote installation failed; checking rollback'

        # Remove only containers with verified project/service/management labels.
        rollback_remote_containers ||
            wplab_info 'Container rollback incomplete; manual inspection required'
        rollback_remote_files ||
            wplab_info 'Runtime file rollback incomplete; manual inspection required'
        rollback_compose_socket_network ||
            wplab_info 'Socket network rollback incomplete; manual inspection required'
        rollback_remote_networks ||
            wplab_info 'Network rollback incomplete; manual inspection required'
        report_mailpit_volume || :
    fi

    return "$exit_status"
}

case "${1:-}" in
    --check)
        check_remote
        ;;
    ''|--recover)
        local_recovery=false
        [[ "${1:-}" != --recover ]] || local_recovery=true
        # Fail before acquiring locks or modifying any runtime state.
        [[ "$WPLAB_REMOTE_DEPLOYMENT_ENABLED" == "true" ]] ||
            wplab_fail 'Remote deployment is disabled until installation and rollback are complete'

        acquire_install_lock

        # Register cleanup for installation failures.
        # Rollback remains disarmed until resource creation begins.
        trap remote_install_exit_handler EXIT

        # Installation is deliberately disabled while the preflight still only
        # warns about port conflicts and container ownership is not enforced.
        preflight_remote

        # Recovery is explicit and only accepts the narrow ACME-only state.
        if [[ "$local_recovery" == true ]]; then
            validate_acme_only_recovery
        fi

        # Never automatically overwrite an incomplete installation.
        if [[ "$WPLAB_INSTALL_STATE" == "partial" && "$local_recovery" != true ]]; then
            wplab_fail \
                'Partial WPLab installation detected. Manual inspection required.'
        fi

        # Existing installations require a separate upgrade workflow.
        if [[ "$WPLAB_INSTALL_STATE" == "existing" ]]; then
            wplab_fail \
                'WPLab is already installed. Reinstallation is not supported yet.'
        fi

        validate_remote_ports

        # Determine the user that will run Traefik.
        configure_runtime_identity

        # Validate Compose before modifying runtime files.
        validate_remote_compose
        validate_remote_mailpit_compose

        # Fresh-only install: never adopt even an owned, pre-existing container.
        validate_fresh_container_absence

        # Mutating operations begin here; arm the EXIT rollback handler.
        WPLAB_ROLLBACK_ARMED=true

        render_remote_templates
        create_remote_dashboard_auth

        # Record whether the ACME directory is newly created.
        if [[ ! -e "$root/traefik/remote/letsencrypt" ]]; then
            WPLAB_CREATED_ACME_DIRECTORY=true
        fi
        prepare_acme_storage
        # Do not track a pre-existing ACME file for deletion on recovery.
        if [[ "$local_recovery" != true ]]; then
            record_remote_file "$root/traefik/remote/letsencrypt/acme.json"
        fi

        prepare_remote_networks
        start_remote_infrastructure
        verify_remote_containers

        # Only a verified installation gets persistent identity.
        wplab_write_environment remote "$WPLAB_DOMAIN"
        WPLAB_ROLLBACK_ARMED=false
        trap - EXIT
        wplab_ok 'Remote installation completed'
        ;;
    *)
        wplab_fail "Unsupported remote installer argument: $1"
        ;;
esac
