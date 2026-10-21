<?php
/**
 * Plugin Name: WPLab Mailpit Transport
 * Description: Routes local WordPress mail to the shared Mailpit inbox.
 */

if (!defined('ABSPATH')) {
    exit;
}

add_action('phpmailer_init', static function ($mailer): void {
    $mailer->isSMTP();
    $mailer->Host = 'mailpit';
    $mailer->Port = 1025;
    $mailer->SMTPAuth = false;
    $mailer->SMTPSecure = '';
    $mailer->SMTPAutoTLS = false;
});

add_filter('wp_mail', static function (array $args): array {
    $site = getenv('WPLAB_SITE_NAME');
    if (!is_string($site) || !preg_match('/^[a-z0-9]+(?:-[a-z0-9]+)*$/D', $site)) {
        return $args;
    }
    $headers = $args['headers'] ?? [];
    if (is_string($headers)) {
        $headers = preg_split('/\r?\n/', trim($headers));
    }
    if (!is_array($headers)) {
        $headers = [];
    }
    $headers[] = 'X-WPLab-Site: ' . $site;
    $args['headers'] = $headers;
    return $args;
});
