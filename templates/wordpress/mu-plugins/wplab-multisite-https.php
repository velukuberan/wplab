<?php
/**
 * Plugin Name: WPLab Multisite HTTPS Defaults
 * Description: Initialize new subdomain multisite child sites with HTTPS URLs when the network's main site uses HTTPS.
 * Version: 0.1.0
 */

declare(strict_types=1);

add_filter(
    'wp_initialize_site_args',
    static function (array $args, WP_Site $site, WP_Network $network): array {
        if (!is_multisite() || !is_subdomain_install()) {
            return $args;
        }

        // Only inherit HTTPS when the network's primary site explicitly uses it.
        $main_home = get_blog_option((int) $network->site_id, 'home');
        if (!is_string($main_home) || 'https' !== wp_parse_url($main_home, PHP_URL_SCHEME)) {
            return $args;
        }

        $domain = $site->domain;
        $path = $site->path;
        if (!is_string($domain) || '' === $domain || !is_string($path) || '' === $path) {
            return $args;
        }

        $https_url = untrailingslashit('https://' . $domain . $path);
        if (!isset($args['options']) || !is_array($args['options'])) {
            $args['options'] = array();
        }

        // Respect an explicitly supplied URL from the caller.
        foreach (array('home', 'siteurl') as $option) {
            if (!array_key_exists($option, $args['options'])) {
                $args['options'][$option] = $https_url;
            }
        }

        return $args;
    },
    10,
    3
);
