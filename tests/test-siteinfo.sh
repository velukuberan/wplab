#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$XDG_CONFIG_HOME/wplab" "$TMP/sites/castle"
SITE="$TMP/sites/castle"
cat > "$SITE/.env" <<'ENV'
SITE_NAME=castle
SITE_URL=https://castle.wplab.test
WP_VERSION=6.9
PHP_VERSION=8.3
MARIADB_VERSION=11
ADMIN_USER=admin
ADMIN_PASS=secret-test-only
ADMIN_EMAIL=admin@example.test
ENV
jq -n --arg p "$SITE" '{castle:{path:$p},missing:{path:"/tmp/nonexistent-wplab-siteinfo-test"}}' > "$XDG_CONFIG_HOME/wplab/sites.json"
listing=$("$ROOT/bin/siteinfo")
grep -q castle <<< "$listing"
grep -q Missing <<< "$listing"
detail=$("$ROOT/bin/siteinfo" castle)
grep -q 'https://castle.wplab.test' <<< "$detail"
if grep -q 'secret-test-only' <<< "$detail"; then echo 'Password leaked' >&2; exit 1; fi
[[ "$("$ROOT/bin/siteinfo" castle --password-only)" == 'secret-test-only' ]]
if "$ROOT/bin/siteinfo" missing >/dev/null 2>&1; then echo 'Missing site unexpectedly succeeded' >&2; exit 1; fi
if "$ROOT/bin/siteinfo" badname >/dev/null 2>&1; then echo 'Unknown site unexpectedly succeeded' >&2; exit 1; fi
printf 'not-json' > "$XDG_CONFIG_HOME/wplab/sites.json"
if "$ROOT/bin/siteinfo" >/dev/null 2>&1; then echo 'Invalid JSON unexpectedly succeeded' >&2; exit 1; fi
echo 'PASS: siteinfo tests'
