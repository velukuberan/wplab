#!/usr/bin/env bash
# Mocked integration tests for WPL-019 remote transaction helpers.
# No real Docker, services, credentials, or installation identity is accessed.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REMOTE="$ROOT/installers/remote.sh"
[[ -f "$REMOTE" ]] || { echo "Missing installer: $REMOTE" >&2; exit 1; }

passed=0
failed=0
run_case() {
    local title="$1"; shift
    if ( "$@" ); then
        printf 'PASS: %s\n' "$title"
        ((passed+=1))
    else
        printf 'FAIL: %s\n' "$title" >&2
        ((failed+=1))
    fi
}
load_fn() {
    local code
    code="$(sed -n "/^$1()/,/^}/p" "$REMOTE")"
    [[ -n "$code" ]] || { echo "Missing function: $1" >&2; return 1; }
    eval "$code"
}
wplab_ok() { :; }
wplab_info() { :; }
wplab_fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# Fail closed: every test must override docker() explicitly.
docker() { echo "UNEXPECTED docker call: $*" >&2; return 99; }

fixture() {
    root="$(mktemp -d)"
    trap 'rm -rf -- "$root"' EXIT
    HOME="$root/home"
    export HOME
    mkdir -p "$HOME" "$root/traefik/remote" "$root/mailpit/remote" "$root/config"
    : > "$root/traefik/remote/docker-compose.yml"
    : > "$root/mailpit/remote/docker-compose.yml"
    : > "$root/config/remote.secrets.env"
}

case_startup_order() {
    load_fn start_remote_infrastructure
    fixture
    WPLAB_DOMAIN=test.vkuberan.in
    remote_provider_compose_file() {
        printf '%s\n' "$root/traefik/remote/providers/digitalocean.compose.yml"
    }
    track_remote_containers() { :; }
    check_compose_socket_absent() { :; }
    track_compose_socket_network() { :; }
    report_mailpit_volume() { :; }
    local log="$root/calls"
    docker() {
        if [[ "$*" == *"$root/mailpit/remote/docker-compose.yml"* ]]; then
            [[ "${WPLAB_DOMAIN:-}" == test.vkuberan.in ]] || return 1
        fi
        printf '%s\n' "$*" >> "$log"
    }
    start_remote_infrastructure
    mapfile -t calls < "$log"
    [[ "${#calls[@]}" == 2 ]] &&
    [[ "${calls[0]}" == "compose --env-file $root/config/remote.secrets.env -f $root/traefik/remote/docker-compose.yml -f $root/traefik/remote/providers/digitalocean.compose.yml up -d" ]] &&
    [[ "${calls[1]}" == "compose -f $root/mailpit/remote/docker-compose.yml up -d" ]]
}

case_startup_failure_stops_second_stage() {
    load_fn start_remote_infrastructure
    fixture
    WPLAB_DOMAIN=test.vkuberan.in
    remote_provider_compose_file() {
        printf '%s\n' "$root/traefik/remote/providers/digitalocean.compose.yml"
    }
    track_remote_containers() { :; }
    check_compose_socket_absent() { :; }
    track_compose_socket_network() { :; }
    report_mailpit_volume() { :; }
    local log="$root/calls" result
    docker() { printf '%s\n' "$*" >> "$log"; return 1; }
    if result="$(start_remote_infrastructure 2>&1)"; then
        echo 'Startup failure unexpectedly accepted' >&2
        return 1
    fi
    [[ "$result" == *'Failed starting WPLab Traefik infrastructure'* ]] &&
    [[ "$(wc -l < "$log")" == 1 ]]
}

case_verify_running_and_ownership() {
    load_fn verify_remote_containers
    remote_container_owned() { :; }
    docker() {
        [[ "$1 $2 $4" == 'container inspect --format' ]] || return 1
        case "$5" in
            '{{.State.Running}}') printf 'true\n' ;;
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}') printf 'healthy\n' ;;
            *) return 1 ;;
        esac
    }
    verify_remote_containers
}

case_nonrunning_mailpit_rejected() {
    load_fn verify_remote_containers
    remote_container_owned() { :; }
    docker() {
        case "$5" in
            '{{.State.Running}}')
                if [[ "$3" == wplab-mailpit ]]; then printf 'false\n'; else printf 'true\n'; fi ;;
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}') printf 'healthy\n' ;;
            *) return 1 ;;
        esac
    }
    local result
    if result="$(verify_remote_containers 2>&1)"; then return 1; fi
    [[ "$result" == *'WPLab container is not running: wplab-mailpit'* ]]
}

case_missing_healthcheck_rejected() {
    load_fn verify_remote_containers
    remote_container_owned() { :; }
    docker() {
        case "$5" in
            '{{.State.Running}}') printf 'true\n' ;;
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}') printf 'none\n' ;;
            *) return 1 ;;
        esac
    }
    local result
    if result="$(verify_remote_containers 2>&1)"; then return 1; fi
    [[ "$result" == *'WPLab service has no health check: wplab-traefik'* ]]
}

case_starting_becomes_healthy() {
    load_fn verify_remote_containers
    fixture
    remote_container_owned() { :; }
    local counter="$root/health_count"
    sleep() { :; }
    docker() {
        case "$5" in
            '{{.State.Running}}') printf 'true\n' ;;
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
                if [[ "$3" == wplab-traefik && ! -f "$counter" ]]; then
                    touch "$counter"
                    printf 'starting\n'
                else
                    printf 'healthy\n'
                fi ;;
            *) return 1 ;;
        esac
    }
    verify_remote_containers && [[ -f "$counter" ]]
}

case_persistent_unhealthy_rejected() {
    load_fn verify_remote_containers
    remote_container_owned() { :; }
    sleep() { :; }
    docker() {
        case "$5" in
            '{{.State.Running}}') printf 'true\n' ;;
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}') printf 'unhealthy\n' ;;
            *) return 1 ;;
        esac
    }
    local result
    if result="$(verify_remote_containers 2>&1)"; then return 1; fi
    [[ "$result" == *'WPLab service not healthy (unhealthy): wplab-traefik'* ]]
}

case_rollback_order_and_exit_code() {
    load_fn remote_install_exit_handler
    fixture
    local log="$root/rollback.log" status=0
    rollback_remote_containers() { printf 'containers\n' >> "$log"; }
    rollback_remote_files() { printf 'files\n' >> "$log"; }
    rollback_remote_networks() { printf 'networks\n' >> "$log"; }
    rollback_compose_socket_network() { :; }
    report_mailpit_volume() { :; }
    (
        WPLAB_ROLLBACK_ARMED=true
        trap remote_install_exit_handler EXIT
        exit 17
    ) || status=$?
    [[ "$status" == 17 ]] &&
    [[ "$(paste -sd, "$log")" == 'containers,files,networks' ]]
}

case_success_no_rollback() {
    load_fn remote_install_exit_handler
    fixture
    local log="$root/rollback.log"
    rollback_remote_containers() { printf 'unexpected\n' >> "$log"; }
    rollback_remote_files() { printf 'unexpected\n' >> "$log"; }
    rollback_remote_networks() { printf 'unexpected\n' >> "$log"; }
    rollback_compose_socket_network() { :; }
    report_mailpit_volume() { :; }
    (
        WPLAB_ROLLBACK_ARMED=true
        trap remote_install_exit_handler EXIT
        exit 0
    )
    [[ ! -e "$log" ]]
}

case_identity_only_after_verification() {
    # Structural contract of the actual installation branch. This ensures
    # persistent identity cannot be written before health verification.
    local start verify identity disarm
    start=$(grep -n '^[[:space:]]*start_remote_infrastructure$' "$REMOTE" | tail -1 | cut -d: -f1)
    verify=$(grep -n '^[[:space:]]*verify_remote_containers$' "$REMOTE" | tail -1 | cut -d: -f1)
    identity=$(grep -n '^[[:space:]]*wplab_write_environment remote ' "$REMOTE" | tail -1 | cut -d: -f1)
    disarm=$(grep -n '^[[:space:]]*WPLAB_ROLLBACK_ARMED=false$' "$REMOTE" | tail -1 | cut -d: -f1)
    [[ -n "$start" && -n "$verify" && -n "$identity" && -n "$disarm" ]] &&
    (( start < verify && verify < identity && identity < disarm ))
}

run_case 'Traefik starts before Mailpit (mocked)' case_startup_order
run_case 'Traefik startup failure prevents Mailpit startup' case_startup_failure_stops_second_stage
run_case 'All running owned containers pass verification' case_verify_running_and_ownership
run_case 'Non-running Mailpit is rejected' case_nonrunning_mailpit_rejected
run_case 'Missing health check fails closed' case_missing_healthcheck_rejected
run_case 'Starting health becomes healthy' case_starting_becomes_healthy
run_case 'Persistently unhealthy service rejected' case_persistent_unhealthy_rejected
run_case 'Failed transaction rolls back containers, files, networks in order' case_rollback_order_and_exit_code
run_case 'Successful exit does not roll back' case_success_no_rollback
run_case 'Persistent identity follows successful verification' case_identity_only_after_verification

case_recovery_accepts_acme_account() {
    load_fn validate_acme_only_recovery
    fixture
    WPLAB_INSTALL_STATE=partial
    mkdir -m 700 "$root/traefik/remote/letsencrypt"
    printf '{"dnsresolver":{"Account":{"Email":"test@example.com"},"Certificates":null}}' > "$root/traefik/remote/letsencrypt/acme.json"
    chmod 600 "$root/traefik/remote/letsencrypt/acme.json"
    validate_acme_only_recovery
}

case_recovery_refuses_conflicting_file() {
    load_fn validate_acme_only_recovery
    fixture
    WPLAB_INSTALL_STATE=partial
    mkdir -m 700 "$root/traefik/remote/letsencrypt"
    printf '{"dnsresolver":{"Account":{}}}' > "$root/traefik/remote/letsencrypt/acme.json"
    chmod 600 "$root/traefik/remote/letsencrypt/acme.json"
    touch "$root/traefik/remote/dashboard-users"
    if (validate_acme_only_recovery) >/dev/null 2>&1; then return 1; fi
}

case_recovery_refuses_bad_acme_json() {
    load_fn validate_acme_only_recovery
    fixture
    WPLAB_INSTALL_STATE=partial
    mkdir -m 700 "$root/traefik/remote/letsencrypt"
    printf 'not-json' > "$root/traefik/remote/letsencrypt/acme.json"
    chmod 600 "$root/traefik/remote/letsencrypt/acme.json"
    if (validate_acme_only_recovery) >/dev/null 2>&1; then return 1; fi
}

case_socket_network_id_guard() {
    load_fn rollback_compose_socket_network
    WPLAB_COMPOSE_SOCKET_ID=old-id
    local removed=false
    docker() {
        case "$*" in
            'network inspect wplab-remote-traefik_socket --format '*'com.docker.compose.network'*) printf 'new-id|wplab-remote-traefik|socket\n' ;;
            'network rm '*) removed=true ;;
            *) return 99 ;;
        esac
    }
    rollback_compose_socket_network
    [[ "$removed" == false ]]
}

case_socket_network_cleanup() {
    load_fn rollback_compose_socket_network
    WPLAB_COMPOSE_SOCKET_ID=network-42
    local removed=false
    docker() {
        case "$*" in
            'network inspect wplab-remote-traefik_socket --format '*'com.docker.compose.network'*) printf 'network-42|wplab-remote-traefik|socket\n' ;;
            'network inspect wplab-remote-traefik_socket --format {{len .Containers}}') printf '0\n' ;;
            'network rm network-42') removed=true ;;
            *) return 99 ;;
        esac
    }
    rollback_compose_socket_network
    [[ "$removed" == true ]]
}

case_socket_network_attached_preserved() {
    load_fn rollback_compose_socket_network
    WPLAB_COMPOSE_SOCKET_ID=network-42
    local removed=false
    docker() {
        case "$*" in
            'network inspect wplab-remote-traefik_socket --format '*'com.docker.compose.network'*) printf 'network-42|wplab-remote-traefik|socket\n' ;;
            'network inspect wplab-remote-traefik_socket --format {{len .Containers}}') printf '1\n' ;;
            'network rm '*) removed=true ;;
            *) return 99 ;;
        esac
    }
    rollback_compose_socket_network
    [[ "$removed" == false ]]
}

run_case 'Recover preserved ACME account' case_recovery_accepts_acme_account
run_case 'Recovery rejects conflicting runtime files' case_recovery_refuses_conflicting_file
run_case 'Recovery rejects invalid ACME data' case_recovery_refuses_bad_acme_json
run_case 'Preserve changed Compose socket network' case_socket_network_id_guard
run_case 'Remove owned empty Compose socket network' case_socket_network_cleanup
run_case 'Preserve occupied Compose socket network' case_socket_network_attached_preserved

printf '\nResults: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
