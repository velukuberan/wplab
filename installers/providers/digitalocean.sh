#!/usr/bin/env bash
# DigitalOcean DNS provider adapter for WPLab remote installations.

provider_validate_config() {
    # No additional configuration is currently required.
    # Generic domain and ACME email validation belong to remote.sh.
    return 0
}

provider_validate_secrets() {
    [[ -n ${DO_AUTH_TOKEN:-} ]] ||
        wplab_fail 'DO_AUTH_TOKEN is missing or empty'
}

provider_acme_name() {
    printf '%s\n' 'digitalocean'
}
