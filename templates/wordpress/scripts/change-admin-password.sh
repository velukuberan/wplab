#!/usr/bin/env bash
# Site-local admin password update. Run from the generated site directory.
set -euo pipefail
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -f .env && ! -L .env ]] || fail 'Missing or unsafe .env'
command -v docker >/dev/null || fail 'Docker is required'
command -v python3 >/dev/null || fail 'Python 3 is required'
[[ $(grep -c '^ADMIN_USER=' .env || :) == 1 ]] || fail 'Expected one ADMIN_USER'
[[ $(grep -c '^ADMIN_PASS=' .env || :) == 1 ]] || fail 'Expected one ADMIN_PASS'
admin=$(sed -n 's/^ADMIN_USER=//p' .env)
[[ "$admin" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail 'Invalid ADMIN_USER'

printf 'Change password for %s\n' "$admin"
IFS= read -r -s -p 'New password: ' password || fail 'Cancelled'
printf '\n'
IFS= read -r -s -p 'Confirm password: ' confirm || fail 'Cancelled'
printf '\n'
[[ "$password" == "$confirm" ]] || fail 'Passwords do not match'
unset confirm
[[ -n "$password" ]] || fail 'Password cannot be empty'
# The site .env is also a Make include. Restrict to safely round-trippable chars.
[[ "$password" =~ ^[A-Za-z0-9._@%+=:,!?-]+$ ]] || fail 'Unsupported characters for .env'

# Prepare the replacement before changing the WordPress database.
tmp=$(mktemp ./.env.changepass.XXXXXXXX) || fail 'Cannot prepare .env'
trap 'rm -f -- "$tmp"' EXIT
chmod --reference=.env "$tmp"
if ! printf '%s' "$password" | python3 -c '
import pathlib, sys
src = pathlib.Path(".env").read_text()
secret = sys.stdin.read()
lines = src.splitlines(keepends=True)
new = [("ADMIN_PASS=" + secret + ("\n" if ln.endswith("\n") else ""))
       if ln.startswith("ADMIN_PASS=") else ln for ln in lines]
pathlib.Path(sys.argv[1]).write_text("".join(new))
' "$tmp"; then
  fail 'Unable to prepare .env'
fi

# The secret is supplied through stdin, not the process command line.
php_code=$(cat <<'PHP_CODE'
$username = getenv('WPLAB_ADMIN_USER');
$user = get_user_by('login', $username);
if (!$user || !in_array('administrator', (array) $user->roles, true)) {
    WP_CLI::error('Configured user is not an administrator');
}
$secret = stream_get_contents(STDIN);
if (!is_string($secret) || $secret === '') {
    WP_CLI::error('Invalid password input');
}
wp_set_password($secret, $user->ID);
WP_CLI::success('WordPress password updated');
PHP_CODE
)
if ! printf '%s' "$password" | docker compose exec -T \
    --env "WPLAB_ADMIN_USER=$admin" wordpress wp eval "$php_code" --allow-root; then
    fail 'WordPress update failed; .env unchanged'
fi
unset password
if ! mv -f -- "$tmp" .env; then
    fail 'WordPress changed, but .env could not be replaced; synchronize ADMIN_PASS manually'
fi
trap - EXIT
printf 'WordPress and .env passwords updated.\n'
