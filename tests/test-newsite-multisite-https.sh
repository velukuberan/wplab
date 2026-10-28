#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEWSITE="$ROOT/bin/newsite"
COMPOSE="$ROOT/templates/wordpress/docker-compose.yml.tmpl"
PLUGIN="$ROOT/templates/wordpress/mu-plugins/wplab-multisite-https.php"

passed=0
failed=0

install_mounts_mu_plugins() {
    awk '
        /^  wp-install:$/ { inside = 1; next }
        inside && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/ { exit }
        inside && /^      - \.\/mu-plugins:\/workspace\/mu-plugins:ro$/ {
            found = 1
        }
        END { exit !found }
    ' "$COMPOSE"
}

check() {
    local description="$1"
    shift

    if "$@"; then
        echo "PASS: $description"
        ((passed += 1))
    else
        echo "FAIL: $description"
        ((failed += 1))
    fi
}

plugin_exists() {
    [[ -f "$PLUGIN" ]] &&
        grep -q '^<?php' "$PLUGIN"
}

validation_before_copy() {
    local validation_line copy_line

    validation_line="$(grep -nF \
        '[[ -f "$TEMPLATE_DIR/mu-plugins/wplab-multisite-https.php" ]]' \
        "$NEWSITE" | head -1 | cut -d: -f1)"

    copy_line="$(grep -nF \
        'cp "$TEMPLATE_DIR/mu-plugins/wplab-multisite-https.php"' \
        "$NEWSITE" | head -1 | cut -d: -f1)"

    [[ -n "$validation_line" && -n "$copy_line" ]] &&
        (( validation_line < copy_line ))
}

conditional_copy() {
    grep -Fq \
        'if [[ "$MULTISITE_ENABLED" == "true" && "$MULTISITE_MODE" == "subdomain" ]]; then' \
        "$NEWSITE" || return 1

    local count
    count="$(grep -Fc \
        'cp "$TEMPLATE_DIR/mu-plugins/wplab-multisite-https.php"' \
        "$NEWSITE")"

    [[ "$count" -eq 1 ]] || return 1

    # Verify that the actual copy operation is inside the intended condition.
    awk '
        /if \[\[ "\$MULTISITE_ENABLED" == "true" && "\$MULTISITE_MODE" == "subdomain" \]\]; then/ {
            inside = 1
            next
        }
        inside && /^[[:space:]]*fi[[:space:]]*$/ {
            inside = 0
        }
        inside && /cp "\$TEMPLATE_DIR\/mu-plugins\/wplab-multisite-https.php"/ {
            found = 1
        }
        END { exit !found }
    ' "$NEWSITE"
}

install_waits_for_link() {
    awk '
        /^  wp-install:$/ { inside = 1; next }
        inside && /^  [a-zA-Z][a-zA-Z0-9_-]*:$/ { exit }
        inside && /^      wp-link:$/ {
            if (getline > 0 && $0 ~ /condition: service_completed_successfully/) {
                found = 1
            }
        }
        END { exit !found }
    ' "$COMPOSE"
}

check "HTTPS MU-plugin template exists" plugin_exists
check "HTTPS plugin validated before copying" validation_before_copy
check "HTTPS plugin copied conditionally" conditional_copy
check "WordPress installation waits for wp-link" install_waits_for_link
check "WordPress installer mounts MU plugins" install_mounts_mu_plugins

printf '\nResults: %d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
