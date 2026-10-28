#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REMOTE="$ROOT/installers/remote.sh"
PROVIDER="$ROOT/installers/providers/digitalocean.sh"

passed=0
failed=0

check() {
    local description="$1"
    shift

    if ( "$@" ); then
        printf 'PASS: %s\n' "$description"
        ((passed+=1))
    else
        printf 'FAIL: %s\n' "$description" >&2
        ((failed+=1))
    fi
}

load_function() {
    local name="$1"
    local source_file="$2"
    local function_code

    function_code=$(sed -n "/^${name}()/,/^}/p" "$source_file")
    [[ -n "$function_code" ]] || return 1

    eval "$function_code"
}

test_provider_selection() {
    load_function load_dns_provider "$REMOTE"

    root="$ROOT"
    WPLAB_DNS_PROVIDER=digitalocean

    wplab_fail() { return 1; }

    load_dns_provider
    [[ "$(provider_acme_name)" == digitalocean ]]
}

test_unsupported_provider() {
    load_function load_dns_provider "$REMOTE"

    root="$ROOT"
    WPLAB_DNS_PROVIDER=unsupported

    wplab_fail() {
        printf 'ERROR: %s\n' "$*" >&2
        exit 1
    }

    if (load_dns_provider) >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

test_missing_credentials() {
    source "$PROVIDER"

    wplab_fail() { return 1; }

    unset DO_AUTH_TOKEN
    ! provider_validate_secrets
}

test_valid_credentials() {
    source "$PROVIDER"

    wplab_fail() { return 1; }

    DO_AUTH_TOKEN=example-test-token
    provider_validate_secrets
}

test_provider_name() {
    source "$PROVIDER"
    [[ "$(provider_acme_name)" == digitalocean ]]
}

test_compose_validation_uses_provider_override() {
    load_function validate_remote_compose "$REMOTE"

    local calls
    calls="$(mktemp)"
    trap 'rm -f "$calls"' RETURN

    root="$ROOT"

    wplab_project_root() {
        printf '%s\n' "$ROOT"
    }

    WPLAB_UID=1000
    WPLAB_GID=1000

    remote_provider_compose_file() {
        printf '%s\n' "$root/traefik/remote/providers/digitalocean.compose.yml"
    }

    wplab_ok() {
        :
    }

    wplab_fail() {
        printf 'ERROR: %s\n' "$*" >&2
        exit 1
    }

    docker() {
        printf '%s\n' "$*" >> "$calls"
    }

    validate_remote_compose || return 1

    grep -Fxq \
        "compose --env-file $root/config/remote.secrets.env -f $root/traefik/remote/docker-compose.yml -f $root/traefik/remote/providers/digitalocean.compose.yml config --quiet" \
        "$calls"
}

check 'DigitalOcean provider loads successfully' test_provider_selection
check 'Unsupported provider is rejected' test_unsupported_provider
check 'Missing DigitalOcean credentials are rejected' test_missing_credentials
check 'Configured DigitalOcean credentials are accepted' test_valid_credentials
check 'Traefik ACME provider name is correct' test_provider_name
check 'Compose validation includes DigitalOcean override' \
    test_compose_validation_uses_provider_override

printf '\nResults: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
