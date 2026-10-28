# wplab

Local WordPress development lab for creating and managing disposable Docker environments.

## Goals

WP Lab provides isolated local WordPress environments for plugin and theme development and compatibility testing.

Each site is created as a self-contained project in the directory where it is generated.

## Planned workflow

Create a site from a configuration file:

    newsite site.json

For example:

    {
        "name": "example",
        "wordpress": "latest",
        "php": "8.3",
        "mariadb": "11"
    }

If `site.json` defines the site name as `example`, running the command from:

    ~/wordpress-projects/

creates:

    ~/wordpress-projects/example/

Created sites are registered globally so they can be discovered and managed regardless of the current working directory.

List managed sites:

    siteinfo

Destroy a site:

    killsite example

Destroying a site removes its Docker resources, project directory, and global registry entry.

## WordPress development

Generated environments are intended to support development of both:

    plugins/
    mu-plugins/

Each environment will provide its own WordPress, PHP, database, web server, and development tooling.

## Remote installation (experimental)

WPLab separates **WordPress site definitions** from **infrastructure configuration**. A site JSON specifies what to build (WordPress, PHP, MariaDB, multisite settings). The installed WPLab environment determines where and how the site runs (hostname, proxy, TLS, networks, and shared services). The same `newsite <config.json>` workflow is used across local and remote environments.

Remote infrastructure currently supports **DigitalOcean DNS**, Docker Compose, Traefik with Let's Encrypt DNS-01, a restricted Docker socket proxy, and shared Mailpit. AWS/Route 53 and other providers are not yet implemented.

### Deployment gate and configuration

**Remote deployment is deliberately disabled in the committed source:**

```bash
WPLAB_REMOTE_DEPLOYMENT_ENABLED=false
```

The guard is in `installers/remote.sh`. Therefore, `bash install.sh --remote` will refuse to deploy in a normal checkout. The installer is currently an experimental, guarded foundation—not a supported production installation interface.

Relevant files:

- `config/remote.env.example` — sample remote domain, ACME email, and DNS provider settings.
- `config/remote.env` — locally configured remote environment (user-owned, mode `600`).
- `config/remote.secrets.env` — DigitalOcean DNS API credentials (user-owned, mode `600`; never commit or print).
- `bash install.sh --remote --check` — read-only preflight and configuration checks.

Isolated test droplets were used to verify remote installation with explicit, temporary test-only activation of the deployment gate. The committed source remains gated; this testing procedure is **not** a production deployment recommendation.

### Verified capabilities

- Fresh remote infrastructure provisioning with Traefik and Mailpit health verification.
- WordPress site routing through Traefik's Docker provider.
- Subdirectory and subdomain multisite support; automatic request and issuance of nested wildcard TLS certificates for subdomain multisite.
- New subdomain multisite child-site HTTPS defaults through the `wplab-multisite-https.php` must-use plugin; tested using WP-CLI and verified in a browser.
- Private socket-proxy connectivity; allowed read-only Docker API requests and denied selected unwanted endpoints; no published socket-proxy host port.
- ACME storage permissions (`700` directory, `600` file), configuration file permissions (`600`), and guarded rollback/recovery tests.
- Automated verification: **40 passing tests** across the four suites below, and a passing GitHub Actions workflow.

```bash
bash tests/test-remote-installer.sh
bash tests/test-remote-integration.sh
bash tests/test-newsite-multisite-https.sh
python3 tests/test-newsite-tls.py
```

### Known limitations

- **Certificate issuance is verified; automatic renewal has not yet been observed.** Traefik is configured for ACME persistence and renewal, but no completed renewal event has been validated.
- Remote deployment remains disabled by default pending further lifecycle and production-readiness review.
- Selected real failure/rollback/recovery cases and mocked failure paths have been tested. These do not cover every possible infrastructure failure.
- The socket proxy has no independent Docker health check, though connectivity and selected access restrictions were tested.
- WP-CLI child-site creation and browser access were validated; creation via the WordPress **Network Admin UI** remains untested.
- Existing VKLab/TestLab infrastructure must not be removed, adopted, or overwritten automatically. A controlled migration/coexistence procedure is not yet documented.
- Reinstallation, upgrades, cloud-provider expansion, and production deployment automation are outside the current remote foundation.

Keep infrastructure credentials, DNS provider settings, and certificate-storage details **out of individual site JSON files**.

## Status

WP Lab is under active development.

The repository was derived from VKLab, a remote disposable testing environment. WPLab is evolving into a local development workflow with an additional, separately managed remote infrastructure capability. The remote installation foundation is currently experimental and guarded.
