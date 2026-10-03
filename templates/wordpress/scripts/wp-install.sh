#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
die() {
    echo "❌ $*" >&2
    exit 1
}

info() {
    echo "▶ $*"
}

ok() {
    echo "✅ $*"
}

# -----------------------------------------------------------------------------
# Required environment
# -----------------------------------------------------------------------------
: "${SITE_URL:?SITE_URL is required}"
: "${SITE_TITLE:?SITE_TITLE is required}"
: "${ADMIN_USER:?ADMIN_USER is required}"
: "${ADMIN_PASS:?ADMIN_PASS is required}"
: "${ADMIN_EMAIL:?ADMIN_EMAIL is required}"

: "${WORDPRESS_DB_HOST:?WORDPRESS_DB_HOST is required}"
: "${WORDPRESS_DB_NAME:?WORDPRESS_DB_NAME is required}"
: "${WORDPRESS_DB_USER:?WORDPRESS_DB_USER is required}"
: "${WORDPRESS_DB_PASSWORD:?WORDPRESS_DB_PASSWORD is required}"

# -----------------------------------------------------------------------------
# Wait for WordPress files
# -----------------------------------------------------------------------------
info "Waiting for WordPress files..."

until [[ -f /var/www/html/wp-load.php ]]; do
    sleep 1
done

# -----------------------------------------------------------------------------
# Wait for database
# -----------------------------------------------------------------------------
info "Waiting for database..."

MAX_ATTEMPTS=30
ATTEMPT=1

until php -r '
    $host = getenv("WORDPRESS_DB_HOST");
    $user = getenv("WORDPRESS_DB_USER");
    $pass = getenv("WORDPRESS_DB_PASSWORD");
    $name = getenv("WORDPRESS_DB_NAME");

    [$host, $port] = array_pad(explode(":", $host, 2), 2, "3306");

    $db = @new mysqli(
        $host,
        $user,
        $pass,
        $name,
        (int) $port
    );

    exit($db->connect_errno ? 1 : 0);
' >/dev/null 2>&1; do
    if [[ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]]; then
        die "Database did not become ready in time."
    fi

    ATTEMPT=$((ATTEMPT + 1))
    sleep 2
done

# -----------------------------------------------------------------------------
# Idempotency
# -----------------------------------------------------------------------------
if wp core is-installed \
    --path=/var/www/html \
    --allow-root \
    >/dev/null 2>&1; then
    ok "WordPress is already installed."
    exit 0
fi

# -----------------------------------------------------------------------------
# Install WordPress
# -----------------------------------------------------------------------------
info "Installing WordPress..."

wp core install \
    --path=/var/www/html \
    --url="$SITE_URL" \
    --title="$SITE_TITLE" \
    --admin_user="$ADMIN_USER" \
    --admin_password="$ADMIN_PASS" \
    --admin_email="$ADMIN_EMAIL" \
    --skip-email \
    --allow-root

ok "WordPress installed successfully."
