#!/usr/bin/env bash
# Verify that registry registration and killsite respect the same advisory lock.
# Runs entirely in temporary directories; does not touch real WPLab sites.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
registry_tool="$root/bin/wplab-registry"
killsite="$root/bin/killsite"
tmp=$(mktemp -d)
child=''
cleanup() {
    if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; fi
    exec 8>&- 2>/dev/null || :
    rm -rf -- "$tmp"
}
trap cleanup EXIT
export WPLAB_CONFIG_DIR="$tmp/config"
mkdir -p "$WPLAB_CONFIG_DIR" "$tmp/sites/castle" "$tmp/sites/woo-100"
printf 'SITE_NAME=castle\nCOMPOSE_PROJECT_NAME=castle\n' >"$tmp/sites/castle/.env"
printf 'SITE_NAME=woo-100\n' >"$tmp/sites/woo-100/.env"
printf 'services: {}\n' >"$tmp/sites/castle/docker-compose.yml"
"$registry_tool" register castle "$tmp/sites/castle"
lock="$WPLAB_CONFIG_DIR/.sites.lock"

# Hold the registry lock while a second process attempts to register a site.
exec 8>"$lock"
flock -x 8
"$registry_tool" register woo-100 "$tmp/sites/woo-100" 8>&- >"$tmp/register.out" 2>&1 &
child=$!
sleep 0.3
if ! kill -0 "$child" 2>/dev/null; then
    echo 'FAIL: register did not wait for the held registry lock' >&2
    exit 1
fi
jq -e 'has("castle") and (has("woo-100") | not)' "$WPLAB_CONFIG_DIR/sites.json" >/dev/null
flock -u 8
wait "$child"
child=''
jq -e 'has("castle") and has("woo-100")' "$WPLAB_CONFIG_DIR/sites.json" >/dev/null

# Hold the same lock while killsite starts; reject at confirmation once released.
flock -x 8
( exec 8>&-; printf 'no\n' | "$killsite" castle ) >"$tmp/killsite.out" 2>&1 &
child=$!
sleep 0.3
if ! kill -0 "$child" 2>/dev/null; then
    echo 'FAIL: killsite did not wait for the held registry lock' >&2
    exit 1
fi
flock -u 8
if wait "$child"; then
    echo 'FAIL: killsite accepted invalid confirmation' >&2
    exit 1
fi
child=''
[[ -d "$tmp/sites/castle" ]]
jq -e 'has("castle") and has("woo-100")' "$WPLAB_CONFIG_DIR/sites.json" >/dev/null
printf 'PASS: registry lock coordination tests\n'
