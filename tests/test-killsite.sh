#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")/.." && pwd)
killsite="$script_dir/bin/killsite"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export WPLAB_CONFIG_DIR="$tmp/config"
mkdir -p "$WPLAB_CONFIG_DIR" "$tmp/sites/castle" "$tmp/mockbin"
cat >"$tmp/mockbin/make" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -f && "$3" == destroy ]] || exit 99
[[ "$2" == */templates/wordpress/Makefile.tmpl ]] || exit 98
[[ "${FAIL_MAKE:-0}" == 0 ]]
MOCK
chmod +x "$tmp/mockbin/make"
export PATH="$tmp/mockbin:$PATH"
site="$tmp/sites/castle"
printf 'SITE_NAME=castle\nCOMPOSE_PROJECT_NAME=castle\n' > "$site/.env"
printf 'services: {}\n' > "$site/docker-compose.yml"
printf 'destroy:\n\t@docker compose down -v\n' > "$site/Makefile"
printf '{"castle":{"path":"%s"}}\n' "$site" > "$WPLAB_CONFIG_DIR/sites.json"
if printf 'no\n' | "$killsite" castle >/dev/null 2>&1; then echo 'FAIL: cancellation accepted'; exit 1; fi
[[ -d "$site" ]] && jq -e 'has("castle")' "$WPLAB_CONFIG_DIR/sites.json" >/dev/null
if printf 'castle\n' | env FAIL_MAKE=1 "$killsite" castle >/dev/null 2>&1; then echo 'FAIL: failed cleanup accepted'; exit 1; fi
[[ -d "$site" ]] && jq -e 'has("castle")' "$WPLAB_CONFIG_DIR/sites.json" >/dev/null
printf 'castle\n' | "$killsite" castle >/dev/null
[[ ! -e "$site" ]] && jq -e 'has("castle") | not' "$WPLAB_CONFIG_DIR/sites.json" >/dev/null
[[ -f "$WPLAB_CONFIG_DIR/.sites.lock" ]]
[[ ! -e "$WPLAB_CONFIG_DIR/sites.lock" ]]
printf 'PASS: killsite tests\n'
