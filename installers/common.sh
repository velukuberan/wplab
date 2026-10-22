#!/usr/bin/env bash
# Shared WPLab installer utilities.

wplab_fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

wplab_info() {
    printf '▶ %s\n' "$*"
}

wplab_ok() {
    printf '✓ %s\n' "$*"
}

wplab_project_root() {
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P
}

wplab_require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 ||
            wplab_fail "Missing prerequisite: $cmd"
    done
}

wplab_validate_environment() {
    local expected_mode="$1"
    local expected_domain="$2"
    local environment_file="$HOME/.config/wplab/environment.env"
    local existing_mode existing_domain

    case "$expected_mode" in
        local|remote) ;;
        *) wplab_fail "Invalid WPLab installation mode: $expected_mode" ;;
    esac

    # Require a lowercase DNS-style domain.
    [[ ${#expected_domain} -le 253 ]] ||
        wplab_fail 'WPLab domain is too long'

    [[ "$expected_domain" =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]+([a-z0-9-]*[a-z0-9])?)+$ ]] ||
        wplab_fail "Invalid WPLab domain: $expected_domain"

    local label
    local -a labels
    IFS='.' read -r -a labels <<< "$expected_domain"

    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 ]] ||
            wplab_fail 'WPLab domain contains an oversized label'
    done

    # Missing configuration is acceptable during first-time installation.
    if [[ ! -e "$environment_file" && ! -L "$environment_file" ]]; then
        return 0
    fi

    [[ -f "$environment_file" && ! -L "$environment_file" ]] ||
        wplab_fail "Unsafe environment configuration: $environment_file"

    [[ -O "$environment_file" ]] ||
        wplab_fail "Environment configuration is not owned by the current user"

    [[ "$(stat -c '%a' "$environment_file")" == "600" ]] ||
        wplab_fail 'Environment configuration must have permissions 600'

    existing_mode=$(
        sed -n 's/^WPLAB_MODE=//p' "$environment_file"
    )

    existing_domain=$(
        sed -n 's/^WPLAB_DOMAIN=//p' "$environment_file"
    )

    [[ "$existing_mode" == "$expected_mode" ]] ||
        wplab_fail \
            "WPLab installation mode conflict: existing=$existing_mode, requested=$expected_mode"

    [[ "$existing_domain" == "$expected_domain" ]] ||
        wplab_fail \
            "WPLab domain conflict: existing=$existing_domain, requested=$expected_domain"

    local expected_content actual_content

    expected_content=$(printf \
        'WPLAB_MODE=%s\nWPLAB_DOMAIN=%s\n' \
        "$expected_mode" "$expected_domain")

    actual_content=$(cat -- "$environment_file") ||
        wplab_fail 'Unable to read WPLab environment configuration'

    # Require exactly the supported keys in canonical order.
    if [[ "$actual_content" != "$expected_content" ]]; then
        existing_mode=$(sed -n 's/^WPLAB_MODE=//p' "$environment_file")
        existing_domain=$(sed -n 's/^WPLAB_DOMAIN=//p' "$environment_file")

        [[ "$existing_mode" == "$expected_mode" ]] ||
            wplab_fail \
                "WPLab installation mode conflict: existing=$existing_mode, requested=$expected_mode"

        [[ "$existing_domain" == "$expected_domain" ]] ||
            wplab_fail \
                "WPLab domain conflict: existing=$existing_domain, requested=$expected_domain"

        wplab_fail 'Malformed or unexpected WPLab environment configuration'
    fi

    wplab_ok 'Existing WPLab environment configuration matches'
}

wplab_write_environment() {
    local mode="$1"
    local domain="$2"
    local config_dir="$HOME/.config/wplab"
    local config_file="$config_dir/environment.env"
    local temp_file

    # Validate before attempting any writes.
    wplab_validate_environment "$mode" "$domain"

    # Preserve matching existing configurations.
    if [[ -e "$config_file" ]]; then
        wplab_ok 'Existing WPLab environment preserved'
        return 0
    fi

    # Validate the parent directory.
    if [[ -e "$config_dir" || -L "$config_dir" ]]; then
        [[ -d "$config_dir" && ! -L "$config_dir" && -O "$config_dir" ]] ||
            wplab_fail "Unsafe WPLab configuration directory: $config_dir"
    else
        install -d -m 700 "$config_dir" ||
            wplab_fail 'Unable to create WPLab configuration directory'
    fi

    # Stage a complete file in the destination filesystem.
    temp_file=$(mktemp "$config_dir/.environment.XXXXXXXX") ||
        wplab_fail 'Unable to create temporary environment configuration'

    if ! (
        umask 077
        printf 'WPLAB_MODE=%s\nWPLAB_DOMAIN=%s\n' \
            "$mode" "$domain" > "$temp_file"
        chmod 600 "$temp_file"
    ); then
        rm -f -- "$temp_file"
        wplab_fail 'Unable to prepare environment configuration'
    fi

    # Publish without overwriting an existing configuration.
    if ! ln -- "$temp_file" "$config_file"; then
        rm -f -- "$temp_file"
        wplab_fail 'Unable to publish WPLab environment configuration'
    fi

    rm -f -- "$temp_file"

    wplab_ok "WPLab environment configured ($mode: $domain)"
}
