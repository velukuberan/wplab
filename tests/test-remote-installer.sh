#!/usr/bin/env bash
# Read-only tests for WPL-019 remote installer helpers.
# No real Docker invocation, no remote installation, no credentials required.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REMOTE="$ROOT/installers/remote.sh"
[[ -f "$REMOTE" ]] || { echo "Missing $REMOTE" >&2; exit 1; }

passed=0
failed=0
run_case() {
    local label="$1"; shift
    if ( "$@" ); then
        printf 'PASS: %s\n' "$label"
        ((passed+=1))
    else
        printf 'FAIL: %s\n' "$label" >&2
        ((failed+=1))
    fi
}

# Extract a whole top-level Bash function from the real installer.
# Test executions happen in a subshell and override Docker with shell mocks.
load_fn() {
    local name="$1"
    local code
    code="$(sed -n "/^${name}()/,/^}/p" "$REMOTE")"
    [[ -n "$code" ]] || { printf 'Missing function: %s\n' "$name" >&2; return 1; }
    eval "$code"
}

mock_log=""
mock_docker() { echo "UNEXPECTED real-or-unknown docker call: $*" >&2; return 70; }
wplab_ok() { :; }
wplab_info() { :; }
wplab_fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case_gate() {
    grep -Eq '^WPLAB_REMOTE_DEPLOYMENT_ENABLED=false$' "$REMOTE" &&
    bash -n "$REMOTE"
}

case_network_tracking() {
    load_fn prepare_remote_networks
    WPLAB_CREATED_NETWORKS=()
    WPLAB_CREATED_NETWORK_IDS=()
    validate_remote_networks() { :; }
    docker() {
        case "$*" in
            'network inspect web') return 0 ;;
            'network inspect wplab-mail') return 1 ;;
            'info') return 0 ;;
            'network ls --format {{.Name}}') printf 'web\n' ;;
            'network create --driver bridge wplab-mail') printf 'network-id-42\n' ;;
            *) mock_docker "$@" ;;
        esac
    }
    prepare_remote_networks &&
    [[ "${#WPLAB_CREATED_NETWORKS[@]}" == 1 ]] &&
    [[ "${WPLAB_CREATED_NETWORKS[0]}" == 'wplab-mail' ]] &&
    [[ "${WPLAB_CREATED_NETWORK_IDS[0]}" == 'network-id-42' ]]
}

case_network_rollback() {
    load_fn rollback_remote_networks
    WPLAB_CREATED_NETWORKS=(wplab-mail)
    WPLAB_CREATED_NETWORK_IDS=(network-id-42)
    local removed=""
    docker() {
        case "$*" in
            'network inspect wplab-mail --format {{.Id}}') printf 'network-id-42\n' ;;
            'network inspect wplab-mail --format {{len .Containers}}') printf '0\n' ;;
            'network rm network-id-42') removed='network-id-42' ;;
            *) mock_docker "$@" ;;
        esac
    }
    rollback_remote_networks
    [[ "$removed" == 'network-id-42' ]]
}

case_network_id_mismatch() {
    load_fn rollback_remote_networks
    WPLAB_CREATED_NETWORKS=(wplab-mail)
    WPLAB_CREATED_NETWORK_IDS=(network-id-42)
    local removed=false
    docker() {
        case "$*" in
            'network inspect wplab-mail --format {{.Id}}') printf 'another-network-id\n' ;;
            'network rm '*) removed=true ;;
            *) mock_docker "$@" ;;
        esac
    }
    rollback_remote_networks
    [[ "$removed" == false ]]
}

case_network_attached() {
    load_fn rollback_remote_networks
    WPLAB_CREATED_NETWORKS=(wplab-mail)
    WPLAB_CREATED_NETWORK_IDS=(network-id-42)
    local removed=false
    docker() {
        case "$*" in
            'network inspect wplab-mail --format {{.Id}}') printf 'network-id-42\n' ;;
            'network inspect wplab-mail --format {{len .Containers}}') printf '1\n' ;;
            'network rm '*) removed=true ;;
            *) mock_docker "$@" ;;
        esac
    }
    rollback_remote_networks
    [[ "$removed" == false ]]
}

case_web_protected() {
    load_fn rollback_remote_networks
    WPLAB_CREATED_NETWORKS=(web)
    WPLAB_CREATED_NETWORK_IDS=(some-id)
    docker() { mock_docker "$@"; }
    rollback_remote_networks
}

case_container_ownership() {
    load_fn remote_container_owned
    docker() {
        case "$*" in
            *'wplab-traefik'*'--format'*) printf 'wplab-remote-traefik|traefik|true\n' ;;
            *) mock_docker "$@" ;;
        esac
    }
    remote_container_owned wplab-traefik wplab-remote-traefik traefik &&
    ! remote_container_owned wplab-traefik unrelated-project traefik &&
    ! remote_container_owned wplab-traefik wplab-remote-traefik mailpit
}

case_unowned_container_preserved() {
    load_fn remote_container_owned
    load_fn rollback_remote_containers
    local removed=false
    WPLAB_CREATED_CONTAINER_IDS=()
    WPLAB_CREATED_CONTAINER_NAMES=()
    docker() {
        case "$*" in
            'container inspect '*)
                [[ "$*" == *'wplab-mailpit'* ]] ;;
            *'wplab-mailpit'*'--format'*) printf 'vklab|mailpit|false\n' ;;
            'container rm '*) removed=true ;;
            *) mock_docker "$@" ;;
        esac
    }
    rollback_remote_containers
    [[ "$removed" == false ]]
}

case_fresh_container_rejected() {
    load_fn validate_fresh_container_absence
    docker() {
        case "$*" in
            'container inspect wplab-traefik') return 0 ;;
            *) mock_docker "$@" ;;
        esac
    }
    if ( validate_fresh_container_absence ) >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

case_rollback_files_inodes() {
    load_fn rollback_remote_files
    local tmp one two
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' RETURN
    root="$tmp/project"
    mkdir -p "$root/traefik/remote"
    one="$tmp/delete-me"
    two="$tmp/preserve-me"
    printf x > "$one"
    printf y > "$two"
    WPLAB_CREATED_FILES=("$one" "$two")
    WPLAB_CREATED_FILE_INODES=("$(stat -c '%d:%i' "$one")" 'nonmatching-inode')
    WPLAB_CREATED_ACME_DIRECTORY=false
    rollback_remote_files
    [[ ! -e "$one" && -f "$two" ]]
}

case_acme_content_preserved() {
    load_fn rollback_remote_files
    local tmp acme
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' RETURN
    root="$tmp"
    acme="$tmp/acme.json"
    printf 'certificate data' > "$acme"
    WPLAB_CREATED_FILES=("$acme")
    WPLAB_CREATED_FILE_INODES=("$(stat -c '%d:%i' "$acme")")
    WPLAB_CREATED_ACME_DIRECTORY=false
    rollback_remote_files
    [[ -f "$acme" ]]
}

case_exit_trap() {
    load_fn remote_install_exit_handler
    rollback_remote_containers() { printf 'C'; }
    rollback_remote_files() { printf 'F'; }
    rollback_remote_networks() { printf 'N'; }
    local output
    output="$( (WPLAB_ROLLBACK_ARMED=false; trap remote_install_exit_handler EXIT; exit 1) )" || :
    [[ "$output" != *CFN* ]] || return 1
    output="$( (WPLAB_ROLLBACK_ARMED=true; trap remote_install_exit_handler EXIT; exit 1) )" || :
    [[ "$output" == *CFN* ]] || return 1
    output="$( (WPLAB_ROLLBACK_ARMED=true; trap remote_install_exit_handler EXIT; exit 0) )"
    [[ "$output" != *CFN* ]]
}

run_case 'Deployment gate disabled and Bash syntax valid' case_gate
run_case 'Preserve web and track new mail network ID' case_network_tracking
run_case 'Rollback network by recorded ID' case_network_rollback
run_case 'Do not remove network after ID change' case_network_id_mismatch
run_case 'Do not remove network with containers' case_network_attached
run_case 'Never remove shared web network' case_web_protected
run_case 'Validate project/service/management container labels' case_container_ownership

case_container_id_mismatch_preserved() {
    load_fn rollback_remote_containers
    WPLAB_CREATED_CONTAINER_NAMES=(wplab-traefik)
    WPLAB_CREATED_CONTAINER_IDS=(original-id)
    local removed=false
    remote_container_owned() { :; }
    docker() {
        case "$*" in
            'container inspect wplab-traefik --format {{.Id}}') printf 'replacement-id\n' ;;
            'container rm '*) removed=true ;;
            *) mock_docker "$@" ;;
        esac
    }
    rollback_remote_containers
    [[ "$removed" == false ]]
}

case_container_id_rollback() {
    load_fn rollback_remote_containers
    WPLAB_CREATED_CONTAINER_NAMES=(wplab-traefik)
    WPLAB_CREATED_CONTAINER_IDS=(original-id)
    local removed=false
    remote_container_owned() { :; }
    docker() {
        case "$*" in
            'container inspect wplab-traefik --format {{.Id}}') printf 'original-id\n' ;;
            'container rm -f original-id') removed=true ;;
            *) mock_docker "$@" ;;
        esac
    }
    rollback_remote_containers
    [[ "$removed" == true ]]
}

run_case 'Preserve unrelated containers' case_unowned_container_preserved
run_case 'Preserve replaced container with changed ID' case_container_id_mismatch_preserved
run_case 'Remove only recorded container ID' case_container_id_rollback
run_case 'Reject existing container during fresh install' case_fresh_container_rejected
run_case 'Delete only tracked files with matching inodes' case_rollback_files_inodes
run_case 'Preserve ACME data once written' case_acme_content_preserved
run_case 'Rollback only on armed failed exit' case_exit_trap

printf '\nResults: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
