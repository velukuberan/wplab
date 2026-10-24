#!/usr/bin/env bash
# WPLab installer entry point.
set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

mode=local
action=install

for arg in "$@"; do
    case "$arg" in
        --remote)
            [[ "$mode" == local ]] || fail 'Duplicate --remote option'
            mode=remote
            ;;
        --recover)
            [[ "$action" == install ]] || fail 'Conflicting installer actions'
            action=recover
            ;;
        --check)
            [[ "$action" == install ]] || fail 'Conflicting installer actions'
            action=check
            ;;
        --setup-dns)
            [[ "$action" == install ]] || fail 'Conflicting installer actions'
            action=setup-dns
            ;;
        --remove-dns)
            [[ "$action" == install ]] || fail 'Conflicting installer actions'
            action=remove-dns
            ;;
        *)
            fail "Unknown argument: $arg"
            ;;
    esac
done

if [[ "$mode" == remote ]]; then
    [[ "$action" == install || "$action" == check || "$action" == recover ]] ||
        fail 'DNS management commands are supported only for local installations'

    installer="$root/installers/remote.sh"
else
    [[ "$action" != recover ]] || fail 'Recovery is supported only for remote installations'
    installer="$root/installers/local.sh"
fi

[[ -f "$installer" ]] || fail "Installer not found: $installer"

case "$action" in
    install)
        exec bash "$installer"
        ;;
    *)
        exec bash "$installer" "--$action"
        ;;
esac
