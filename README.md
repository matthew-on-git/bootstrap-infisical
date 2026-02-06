# Infisical Self-Hosted Install Script

Idempotent installer for [Infisical](https://infisical.com) secret manager on Ubuntu 24.04. Deploys via Docker Compose with optional nginx reverse proxy and Let's Encrypt TLS (HTTP-01 or DNS-01 via Cloudflare).

## What It Deploys

- **Infisical** (pinned version) -- secret management platform
- **PostgreSQL 14** -- encrypted secret storage
- **Redis 7** -- caching and job queues
- **Daily backup cron** -- PostgreSQL dumps with configurable retention
- **Optional: nginx + Let's Encrypt** -- TLS-terminating reverse proxy (skip if behind your own load balancer)

## Prerequisites

- Ubuntu 24.04 VM (cloud-init on Proxmox or similar)
- Root/sudo access
- If TLS mode `letsencrypt-http`: DNS A record and ports 80/443 reachable from the internet
- If TLS mode `dns-cloudflare`: DNS managed by Cloudflare, plus a Cloudflare API token with Zone > DNS > Edit permission
- If TLS mode `off`: your own load balancer (e.g., HAProxy) handling TLS termination

## Usage

### Interactive Mode

```bash
sudo ./install.sh
```

The script prompts for each configuration value with sensible defaults. Press Enter to accept the default shown in brackets.

### Non-Interactive Mode

```bash
sudo ./install.sh -y
```

Skips all prompts. Uses saved configuration from a previous run, or falls back to hardcoded defaults.

### Help

```bash
./install.sh --help
```

## Configuration

The script prompts for:

| Setting | Default | Description |
|---|---|---|
| Domain | `infisical.example.com` | FQDN for the Infisical instance |
| Install directory | `/opt/infisical` | Where Docker Compose files and config live |
| TLS mode | `off` | `off`, `letsencrypt-http`, or `dns-cloudflare` |
| Listen port | `8080` | Port for Infisical (only when TLS mode is `off`) |
| Certbot email | *(required for any TLS mode)* | Email for Let's Encrypt notifications |
| Cloudflare API token | *(required for `dns-cloudflare`)* | Token with Zone > DNS > Edit permission |
| Backup retention | `30` days | How long to keep daily PostgreSQL backups |
| Infisical version | `v0.158.0` | Docker image tag (pinned, not `latest`) |
| PostgreSQL version | `14-alpine` | PostgreSQL Docker image tag |
| Redis version | `7-alpine` | Redis Docker image tag |

Configuration is saved to `/opt/infisical/.install.conf` and automatically loaded as defaults on re-run.

## TLS Modes

### `off` (default) -- behind an external load balancer

- nginx and certbot are **not installed**
- Infisical binds directly to `0.0.0.0:<listen_port>` (default 8080)
- SITE_URL is set to `http://<domain>:<port>`
- Your external HAProxy / load balancer handles TLS termination and proxies to this port

### `letsencrypt-http` -- standalone with nginx + HTTP-01 challenge

- nginx is installed and configured as a reverse proxy
- certbot obtains a certificate via HTTP-01 challenge (requires port 80 reachable from the internet)
- Infisical binds to `127.0.0.1:8080` (not exposed to the network)
- All public traffic goes through nginx on ports 80/443

### `dns-cloudflare` -- standalone with nginx + DNS-01 challenge

- nginx is installed and configured as a reverse proxy
- certbot obtains a certificate via DNS-01 challenge using the Cloudflare API (no inbound port 80 required)
- Cloudflare credentials are stored in `/opt/infisical/.cloudflare-credentials` (chmod 600)
- Infisical binds to `127.0.0.1:8080` (not exposed to the network)
- All public traffic goes through nginx on ports 80/443
- Requires a Cloudflare API token with **Zone > DNS > Edit** permission for the target zone

## Idempotency

The script is designed to be run multiple times safely:

- **Secrets are never regenerated.** `ENCRYPTION_KEY`, `AUTH_SECRET`, and `POSTGRES_PASSWORD` are generated on first run and preserved on every subsequent run. Losing the `ENCRYPTION_KEY` means losing access to all stored secrets.
- **Config files are safely overwritten.** Docker Compose, nginx config (if TLS), and cron jobs are declarative and rewritten each run.
- **Certbot is skipped** if a valid certificate already exists (TLS mode only).
- **Apt installs** are idempotent by nature.
- **`docker compose up -d`** only recreates containers that have changed.

## Files on the Server

After installation:

| Path | Description |
|---|---|
| `/opt/infisical/.env` | Secrets (ENCRYPTION_KEY, AUTH_SECRET, DB password). **Never commit.** |
| `/opt/infisical/.install.conf` | Saved configuration for re-runs |
| `/opt/infisical/docker-compose.yml` | Docker Compose service definitions |
| `/opt/infisical/backups/` | Daily PostgreSQL backup dumps (.sql.gz) |
| `/etc/cron.d/infisical-backup` | Daily backup cron job |
| `/opt/infisical/.cloudflare-credentials` | Cloudflare API token for certbot (`dns-cloudflare` mode only) |
| `/etc/nginx/sites-available/infisical` | nginx reverse proxy config (TLS modes only) |
| `/etc/letsencrypt/live/<domain>/` | TLS certificates (TLS modes only) |

## Common Operations

```bash
# View container status
docker compose -f /opt/infisical/docker-compose.yml ps

# View logs (all containers)
docker compose -f /opt/infisical/docker-compose.yml logs -f

# View backend logs only
docker compose -f /opt/infisical/docker-compose.yml logs -f backend

# Restart all services
docker compose -f /opt/infisical/docker-compose.yml restart

# Stop all services
docker compose -f /opt/infisical/docker-compose.yml down

# Manual database backup
docker exec infisical-db pg_dump -U infisical -d infisical \
  | gzip > /opt/infisical/backups/manual-$(date +%Y%m%d-%H%M%S).sql.gz

# Restore from backup
gunzip -c /opt/infisical/backups/infisical-db-20260131.sql.gz \
  | docker exec -i infisical-db psql -U infisical -d infisical
```

## Upgrading Infisical

1. Re-run the install script
2. When prompted for Infisical version, enter the new version tag (check [Docker Hub](https://hub.docker.com/r/infisical/infisical/tags) for available tags)
3. The script will pull the new image and recreate the backend container

Alternatively, edit `/opt/infisical/.install.conf`, update the `INFISICAL_VERSION` line, and re-run with `-y`.

## Backup and Recovery

**Daily automatic backups** run at 2:00 AM via cron. Backups older than the retention period are automatically deleted.

**Critical**: The `ENCRYPTION_KEY` in `/opt/infisical/.env` is required to decrypt any database backup. Store it separately in your password manager. Without it, backups are useless.

### Disaster Recovery

1. Provision a new Ubuntu 24.04 VM
2. Copy `install.sh` to the new VM
3. Run the script (it will generate new secrets)
4. Stop the containers: `docker compose -f /opt/infisical/docker-compose.yml down`
5. Replace the `ENCRYPTION_KEY` in `/opt/infisical/.env` with the original key
6. Restore the database from backup (see command above)
7. Restart: `docker compose -f /opt/infisical/docker-compose.yml up -d`

## Security Notes

- In TLS mode, the backend binds to `127.0.0.1:8080` only -- not exposed to the network
- In non-TLS mode, the backend binds to `0.0.0.0:<port>` -- ensure your network/firewall restricts access appropriately
- `.env`, `.install.conf`, and `.cloudflare-credentials` are chmod 600 (root-only readable)
- Certbot auto-renewal is handled by Ubuntu's systemd timer (TLS modes only)
- No secrets are stored in this repository
