# WPLab Mailpit (shared service)

Mailpit captures emails from every local WPLab WordPress site. It is managed
independently of generated sites and of Traefik.

## Prerequisites

- Docker and Docker Compose
- The existing Traefik `web` network and reverse proxy
- A local `mail.wplab.test` hostname pointing to Traefik; local TLS certificate covering it

## Start

From the WPLab repository root:

```bash
# Run once; skip when the network already exists.
docker network inspect wplab-mail >/dev/null 2>&1 || docker network create wplab-mail

docker compose -f mailpit/docker-compose.yml config
docker compose -f mailpit/docker-compose.yml up -d
docker compose -f mailpit/docker-compose.yml ps
```

Open https://mail.wplab.test. In Docker, WordPress containers attached to
`wplab-mail` will send SMTP to `mailpit:1025` (no SMTP host port is published).
WordPress routing is added in WPL-015 Stage B, not in this stage.

## Storage and lifecycle

The existing Compose project directory, service/container name, Traefik host,
and named volume are retained. Mail is stored in `mailpit_data` as
`/data/mailpit.db`, with a 5,000-message retention limit. The actual Docker
volume is normally named `mailpit_mailpit_data`; verify with `docker volume ls`.

```bash
# Stop service but keep messages:
docker compose -f mailpit/docker-compose.yml down

# WARNING: This ALSO deletes stored messages. Do not use for routine restarts.
# docker compose -f mailpit/docker-compose.yml down -v
```

The `make destroy` / `killsite` commands for WordPress sites must not delete
this shared service or its volume.

## Existing installation caution

`MP_DATA_FILE` is a legacy Mailpit option. The current option is `MP_DATABASE`.
Before restarting an installation with messages you want to retain, inspect
its actual running database configuration and back up the existing volume.
Simply updating the Compose file cannot recover messages previously held in a
temporary database or removed by retention pruning.

Check the shared network and service:

```bash
docker inspect mailpit --format '{{json .NetworkSettings.Networks}}'
docker logs mailpit --tail=30
```
