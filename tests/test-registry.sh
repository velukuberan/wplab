#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REGISTRY_TOOL="$SCRIPT_DIR/bin/wplab-registry"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
export XDG_CONFIG_HOME="$TEST_HOME/config"
mkdir -p "$TEST_HOME/sites/castle"
printf 'SITE_NAME=castle\n' > "$TEST_HOME/sites/castle/.env"
"$REGISTRY_TOOL" check castle
"$REGISTRY_TOOL" register castle "$TEST_HOME/sites/castle"
jq -e --arg p "$TEST_HOME/sites/castle" '.castle.path == $p' "$XDG_CONFIG_HOME/wplab/sites.json" > /dev/null
if "$REGISTRY_TOOL" check castle 2>/dev/null; then echo 'Duplicate check unexpectedly passed'; exit 1; fi
if "$REGISTRY_TOOL" register castle "$TEST_HOME/sites/castle" 2>/dev/null; then echo 'Duplicate registration unexpectedly passed'; exit 1; fi
[[ $(stat -c %a "$XDG_CONFIG_HOME/wplab/sites.json") == 600 ]]
mkdir -p "$TEST_HOME/sites/woo-100"
printf 'SITE_NAME=woo-100\n' > "$TEST_HOME/sites/woo-100/.env"
"$REGISTRY_TOOL" register woo-100 "$TEST_HOME/sites/woo-100"
jq -e 'has("castle") and has("woo-100")' "$XDG_CONFIG_HOME/wplab/sites.json" >/dev/null
printf 'PASS: registry integration tests\n'
