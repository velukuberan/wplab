#!/usr/bin/env bash

set -euo pipefail

echo "▶ Waiting for WordPress files..."

until [[ -f /var/www/html/wp-load.php ]]; do
    sleep 1
done

link_entries() {
    local source_dir="$1"
    local target_dir="$2"

    mkdir -p "$target_dir"

    shopt -s nullglob

    for source in "$source_dir"/*; do
        name="$(basename "$source")"
        target="$target_dir/$name"

        # Leave existing WordPress/default content untouched.
        if [[ -e "$target" || -L "$target" ]]; then
            continue
        fi

        ln -s "$source" "$target"
    done

    shopt -u nullglob
}

link_entries /workspace/plugins /var/www/html/wp-content/plugins
link_entries /workspace/themes /var/www/html/wp-content/themes
link_entries /workspace/mu-plugins /var/www/html/wp-content/mu-plugins
