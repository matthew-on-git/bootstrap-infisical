#!/usr/bin/env bash
# =============================================================================
# Infisical Self-Hosted Install Script
# Idempotent — safe to run multiple times for troubleshooting or config changes
#
# Deploys: Infisical + PostgreSQL + Redis via Docker Compose
#          Optional: nginx reverse proxy with Let's Encrypt TLS (HTTP-01 or DNS-01 via Cloudflare)
#          Daily PostgreSQL backup cron
#
# Usage:
#   sudo ./install.sh              # Interactive mode (prompts for config)
#   sudo ./install.sh -y           # Non-interactive (use defaults/saved config)
#   sudo ./install.sh --help       # Show help
# =============================================================================
set -euo pipefail

# ---- Defaults (overridden by saved config, then by user input) ----
DEFAULT_DOMAIN="infisical.example.com"
DEFAULT_INSTALL_DIR="/opt/infisical"
DEFAULT_BACKUP_RETENTION_DAYS="30"
DEFAULT_INFISICAL_VERSION="v0.158.0"
DEFAULT_POSTGRES_VERSION="14-alpine"
DEFAULT_REDIS_VERSION="7-alpine"
DEFAULT_CERTBOT_EMAIL=""
DEFAULT_TLS_MODE="off"
DEFAULT_CLOUDFLARE_API_TOKEN=""
DEFAULT_LISTEN_PORT="8080"

# ---- Constants ----
SCRIPT_NAME="$(basename "$0")"
NON_INTERACTIVE=false

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================
log() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error_exit() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

header() {
  echo ""
  echo -e "${BLUE}${BOLD}=== $* ===${NC}"
  echo ""
}

# Prompt for a variable with a default value. Enter accepts the default.
# Usage: prompt_var VAR_NAME "Prompt text" "default_value"
prompt_var() {
  local var_name="$1"
  local prompt_text="$2"
  local default_val="$3"

  if [[ "$NON_INTERACTIVE" == true ]]; then
    eval "${var_name}=\"${default_val}\""
    return
  fi

  local input
  echo -en "  ${prompt_text} [${CYAN}${default_val}${NC}]: "
  # shellcheck disable=SC2034  # input is used in eval below
  read -r input
  eval "${var_name}=\"\${input:-\${default_val}}\""
}

usage() {
  cat << EOF
Usage: sudo $SCRIPT_NAME [OPTIONS]

Idempotent installer for self-hosted Infisical secret manager.

Options:
  -y, --non-interactive   Skip prompts, use defaults or saved configuration
  -h, --help              Show this help message

The script will prompt for configuration values interactively.
Press Enter at any prompt to accept the default (shown in brackets).

On re-run, previously saved configuration values become the new defaults.
EOF
  exit 0
}

# =============================================================================
# Parse Arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y | --yes | --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    -h | --help) usage ;;
    *) error_exit "Unknown option: $1. Use --help for usage." ;;
  esac
done

# =============================================================================
# Pre-flight Checks
# =============================================================================
header "Pre-flight Checks"

# Must be root
if [[ $EUID -ne 0 ]]; then
  error_exit "This script must be run as root (use sudo)"
fi

# Verify Ubuntu
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script is designed for Ubuntu. Detected: ${ID:-unknown}. Proceeding anyway."
  fi
  log "OS: ${PRETTY_NAME:-$ID $VERSION_ID}"
else
  warn "Cannot detect OS. Proceeding anyway."
fi

# Check internet connectivity
if ! ping -c 1 -W 3 1.1.1.1 &> /dev/null; then
  error_exit "No internet connectivity. Cannot proceed with installation."
fi
log "Internet connectivity: OK"

# =============================================================================
# Interactive Configuration
# =============================================================================
header "Configuration"

# Load saved config from previous run (if it exists)
SAVED_CONFIG="${DEFAULT_INSTALL_DIR}/.install.conf"
if [[ -f "$SAVED_CONFIG" ]]; then
  log "Loading saved configuration from previous install..."
  # Source safely — only override DEFAULT_ vars
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    case "$key" in
      DOMAIN) DEFAULT_DOMAIN="$value" ;;
      INSTALL_DIR) DEFAULT_INSTALL_DIR="$value" ;;
      BACKUP_RETENTION_DAYS) DEFAULT_BACKUP_RETENTION_DAYS="$value" ;;
      INFISICAL_VERSION) DEFAULT_INFISICAL_VERSION="$value" ;;
      POSTGRES_VERSION) DEFAULT_POSTGRES_VERSION="$value" ;;
      REDIS_VERSION) DEFAULT_REDIS_VERSION="$value" ;;
      CERTBOT_EMAIL) DEFAULT_CERTBOT_EMAIL="$value" ;;
      TLS_MODE) DEFAULT_TLS_MODE="$value" ;;
      CLOUDFLARE_API_TOKEN) DEFAULT_CLOUDFLARE_API_TOKEN="$value" ;;
      # Backward compat: map old TLS_ENABLED yes/no to new TLS_MODE
      TLS_ENABLED)
        if [[ "$value" == "yes" ]]; then
          DEFAULT_TLS_MODE="letsencrypt-http"
        else
          DEFAULT_TLS_MODE="off"
        fi
        ;;
      LISTEN_PORT) DEFAULT_LISTEN_PORT="$value" ;;
    esac
  done < "$SAVED_CONFIG"
  echo ""
fi

if [[ "$NON_INTERACTIVE" == true ]]; then
  log "Non-interactive mode — using defaults/saved configuration"
fi

prompt_var DOMAIN "Domain name" "$DEFAULT_DOMAIN"
prompt_var INSTALL_DIR "Install directory" "$DEFAULT_INSTALL_DIR"
prompt_var TLS_MODE "TLS mode (off / letsencrypt-http / dns-cloudflare)" "$DEFAULT_TLS_MODE"
# Normalize
TLS_MODE=$(echo "$TLS_MODE" | tr '[:upper:]' '[:lower:]')

if [[ "$TLS_MODE" == "dns-cloudflare" ]]; then
  prompt_var CERTBOT_EMAIL "Let's Encrypt email (required)" "$DEFAULT_CERTBOT_EMAIL"
  prompt_var CLOUDFLARE_API_TOKEN "Cloudflare API token (Zone DNS Edit)" "$DEFAULT_CLOUDFLARE_API_TOKEN"
  LISTEN_PORT=""
elif [[ "$TLS_MODE" == "letsencrypt-http" ]]; then
  prompt_var CERTBOT_EMAIL "Let's Encrypt email (required)" "$DEFAULT_CERTBOT_EMAIL"
  CLOUDFLARE_API_TOKEN=""
  LISTEN_PORT=""
else
  TLS_MODE="off"
  CERTBOT_EMAIL=""
  CLOUDFLARE_API_TOKEN=""
  prompt_var LISTEN_PORT "Listen port for Infisical" "$DEFAULT_LISTEN_PORT"
fi

prompt_var BACKUP_RETENTION_DAYS "Backup retention (days)" "$DEFAULT_BACKUP_RETENTION_DAYS"
prompt_var INFISICAL_VERSION "Infisical version" "$DEFAULT_INFISICAL_VERSION"
prompt_var POSTGRES_VERSION "PostgreSQL version" "$DEFAULT_POSTGRES_VERSION"
prompt_var REDIS_VERSION "Redis version" "$DEFAULT_REDIS_VERSION"

# Derived values
if [[ "$TLS_MODE" != "off" ]]; then
  SITE_URL="https://${DOMAIN}"
else
  if [[ "$LISTEN_PORT" == "80" ]]; then
    SITE_URL="http://${DOMAIN}"
  else
    SITE_URL="http://${DOMAIN}:${LISTEN_PORT}"
  fi
fi
BACKUP_DIR="${INSTALL_DIR}/backups"

# Validate required
if [[ "$TLS_MODE" != "off" && -z "$CERTBOT_EMAIL" ]]; then
  error_exit "Let's Encrypt email is required when TLS is enabled."
fi
if [[ "$TLS_MODE" == "dns-cloudflare" && -z "$CLOUDFLARE_API_TOKEN" ]]; then
  error_exit "Cloudflare API token is required for dns-cloudflare mode."
fi

# Show summary
echo ""
echo -e "${BOLD}Configuration Summary:${NC}"
echo "  ─────────────────────────────────────────────"
echo -e "  Domain:              ${CYAN}${DOMAIN}${NC}"
echo -e "  Site URL:            ${CYAN}${SITE_URL}${NC}"
echo -e "  TLS mode:            ${CYAN}${TLS_MODE}${NC}"
if [[ "$TLS_MODE" == "dns-cloudflare" ]]; then
  echo -e "  Certbot email:       ${CYAN}${CERTBOT_EMAIL}${NC}"
  echo -e "  Cloudflare token:    ${CYAN}(token set)${NC}"
elif [[ "$TLS_MODE" == "letsencrypt-http" ]]; then
  echo -e "  Certbot email:       ${CYAN}${CERTBOT_EMAIL}${NC}"
else
  echo -e "  Listen port:         ${CYAN}${LISTEN_PORT}${NC}"
fi
echo -e "  Install directory:   ${CYAN}${INSTALL_DIR}${NC}"
echo -e "  Backup directory:    ${CYAN}${BACKUP_DIR}${NC}"
echo -e "  Backup retention:    ${CYAN}${BACKUP_RETENTION_DAYS} days${NC}"
echo -e "  Infisical version:   ${CYAN}${INFISICAL_VERSION}${NC}"
echo -e "  PostgreSQL version:  ${CYAN}${POSTGRES_VERSION}${NC}"
echo -e "  Redis version:       ${CYAN}${REDIS_VERSION}${NC}"
echo "  ─────────────────────────────────────────────"
echo ""

if [[ "$NON_INTERACTIVE" != true ]]; then
  read -rp "  Proceed with this configuration? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log "Aborted by user."
    exit 0
  fi
fi

# =============================================================================
# Install System Packages
# =============================================================================
header "Installing System Packages"

export DEBIAN_FRONTEND=noninteractive

# Only update apt cache if it's older than 1 hour
apt_cache_age=$(($(date +%s) - $(stat -c %Y /var/lib/apt/lists/ 2> /dev/null || echo 0)))
if [[ $apt_cache_age -gt 3600 ]]; then
  log "Updating apt package cache..."
  apt-get update -qq
else
  log "Apt cache is recent, skipping update"
fi

PACKAGES=(
  docker.io
  docker-compose-v2
  postgresql-client
  openssl
)

if [[ "$TLS_MODE" == "dns-cloudflare" ]]; then
  PACKAGES+=(nginx certbot python3-certbot-dns-cloudflare)
elif [[ "$TLS_MODE" == "letsencrypt-http" ]]; then
  PACKAGES+=(nginx certbot python3-certbot-nginx)
fi

log "Installing packages: ${PACKAGES[*]}"
apt-get install -y -qq "${PACKAGES[@]}"

# Enable and start services
systemctl enable --now docker
if [[ "$TLS_MODE" != "off" ]]; then
  systemctl enable --now nginx
fi
log "Docker service enabled and running"

# =============================================================================
# Create Directory Structure
# =============================================================================
header "Setting Up Directories"

mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"
if [[ "$TLS_MODE" != "off" ]]; then
  mkdir -p /var/www/certbot
fi
log "Directories created: ${INSTALL_DIR}, ${BACKUP_DIR}"

# Save configuration for next run
cat > "${INSTALL_DIR}/.install.conf" << EOF
# Infisical install configuration — auto-generated, do not commit to VCS
DOMAIN=${DOMAIN}
INSTALL_DIR=${INSTALL_DIR}
TLS_MODE=${TLS_MODE}
CERTBOT_EMAIL=${CERTBOT_EMAIL}
CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
LISTEN_PORT=${LISTEN_PORT}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS}
INFISICAL_VERSION=${INFISICAL_VERSION}
POSTGRES_VERSION=${POSTGRES_VERSION}
REDIS_VERSION=${REDIS_VERSION}
EOF
chmod 600 "${INSTALL_DIR}/.install.conf"
log "Configuration saved to ${INSTALL_DIR}/.install.conf"

# =============================================================================
# Generate / Preserve .env File
# =============================================================================
header "Configuring Secrets (.env)"

EXISTING_ENCRYPTION_KEY=""
EXISTING_AUTH_SECRET=""
EXISTING_POSTGRES_PASSWORD=""

if [[ -f "${INSTALL_DIR}/.env" ]]; then
  log "Existing .env found — preserving secrets"
  EXISTING_ENCRYPTION_KEY=$(grep '^ENCRYPTION_KEY=' "${INSTALL_DIR}/.env" | cut -d'=' -f2- || true)
  EXISTING_AUTH_SECRET=$(grep '^AUTH_SECRET=' "${INSTALL_DIR}/.env" | cut -d'=' -f2- || true)
  EXISTING_POSTGRES_PASSWORD=$(grep '^POSTGRES_PASSWORD=' "${INSTALL_DIR}/.env" | cut -d'=' -f2- || true)
fi

if [[ -n "$EXISTING_ENCRYPTION_KEY" ]]; then
  ENCRYPTION_KEY="$EXISTING_ENCRYPTION_KEY"
  log "ENCRYPTION_KEY: preserved from existing .env"
else
  ENCRYPTION_KEY=$(openssl rand -hex 16)
  log "ENCRYPTION_KEY: generated new key"
  warn "BACK UP THIS KEY! Without it, your encrypted data is irrecoverable."
fi

if [[ -n "$EXISTING_AUTH_SECRET" ]]; then
  AUTH_SECRET="$EXISTING_AUTH_SECRET"
  log "AUTH_SECRET: preserved from existing .env"
else
  AUTH_SECRET=$(openssl rand -base64 32)
  log "AUTH_SECRET: generated new secret"
fi

if [[ -n "$EXISTING_POSTGRES_PASSWORD" ]]; then
  POSTGRES_PASSWORD="$EXISTING_POSTGRES_PASSWORD"
  log "POSTGRES_PASSWORD: preserved from existing .env"
else
  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  log "POSTGRES_PASSWORD: generated new password"
fi

cat > "${INSTALL_DIR}/.env" << EOF
# =============================================================================
# Infisical Environment Configuration
# Auto-generated by install.sh — secrets are preserved across re-runs
# DO NOT commit this file to version control
# =============================================================================

# Encryption — CRITICAL: back up this key separately
ENCRYPTION_KEY=${ENCRYPTION_KEY}

# JWT signing secret
AUTH_SECRET=${AUTH_SECRET}

# PostgreSQL
POSTGRES_USER=infisical
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=infisical
DB_CONNECTION_URI=postgres://infisical:${POSTGRES_PASSWORD}@db:5432/infisical

# Redis
REDIS_URL=redis://redis:6379

# Site URL (must match your nginx/DNS setup)
SITE_URL=${SITE_URL}

# Telemetry (disabled for self-hosted)
TELEMETRY_ENABLED=false
OTEL_TELEMETRY_COLLECTION_ENABLED=false

# SMTP (optional — configure to enable email invitations)
SMTP_HOST=
SMTP_PORT=
SMTP_FROM_ADDRESS=
SMTP_FROM_NAME=
SMTP_USERNAME=
SMTP_PASSWORD=
EOF
chmod 600 "${INSTALL_DIR}/.env"
log ".env written to ${INSTALL_DIR}/.env"

# =============================================================================
# Write Docker Compose File
# =============================================================================
header "Writing Docker Compose Configuration"

# Determine port binding based on TLS mode
if [[ "$TLS_MODE" != "off" ]]; then
  BACKEND_PORT="127.0.0.1:8080:8080"
else
  BACKEND_PORT="0.0.0.0:${LISTEN_PORT}:8080"
fi

cat > "${INSTALL_DIR}/docker-compose.yml" << EOF
services:
  backend:
    container_name: infisical-backend
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    image: infisical/infisical:${INFISICAL_VERSION}
    pull_policy: always
    env_file: .env
    ports:
      - "${BACKEND_PORT}"
    environment:
      - NODE_ENV=production
    networks:
      - infisical

  redis:
    image: redis:${REDIS_VERSION}
    container_name: infisical-redis
    restart: always
    environment:
      - ALLOW_EMPTY_PASSWORD=yes
    networks:
      - infisical
    volumes:
      - redis_data:/data

  db:
    container_name: infisical-db
    image: postgres:${POSTGRES_VERSION}
    restart: always
    env_file: .env
    volumes:
      - pg_data:/var/lib/postgresql/data
    networks:
      - infisical
    healthcheck:
      test: "pg_isready --username=infisical && psql --username=infisical --list"
      interval: 5s
      timeout: 10s
      retries: 10

volumes:
  pg_data:
    driver: local
  redis_data:
    driver: local

networks:
  infisical:
EOF
log "Docker Compose file written to ${INSTALL_DIR}/docker-compose.yml"

# =============================================================================
# Configure nginx Reverse Proxy (TLS mode only)
# =============================================================================
NGINX_CONF="/etc/nginx/sites-available/infisical"

if [[ "$TLS_MODE" != "off" ]]; then
  header "Configuring nginx"

  NGINX_ENABLED="/etc/nginx/sites-enabled/infisical"
  CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

  # Remove default site if it exists
  rm -f /etc/nginx/sites-enabled/default

  # If certs don't exist yet, obtain via the selected TLS mode
  if [[ ! -f "$CERT_PATH" ]]; then
    header "Obtaining TLS Certificate"

    if [[ "$TLS_MODE" == "dns-cloudflare" ]]; then
      # ---- DNS-01 challenge via Cloudflare ----
      CF_CREDS="${INSTALL_DIR}/.cloudflare-credentials"
      log "Writing Cloudflare credentials to ${CF_CREDS}"
      cat > "$CF_CREDS" << EOF
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
EOF
      chmod 600 "$CF_CREDS"

      log "Running certbot with dns-cloudflare plugin for ${DOMAIN}..."
      certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CF_CREDS" \
        -d "$DOMAIN" \
        --email "$CERTBOT_EMAIL" \
        --non-interactive \
        --agree-tos \
        --no-eff-email

    else
      # ---- HTTP-01 challenge via webroot ----
      log "No TLS certificate found — writing HTTP-only config for certbot"

      cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'Infisical is being configured...';
        add_header Content-Type text/plain;
    }
}
EOF

      ln -sf "$NGINX_CONF" "$NGINX_ENABLED"
      nginx -t && systemctl reload nginx
      log "nginx reloaded with HTTP-only config"

      log "Running certbot for ${DOMAIN}..."
      certbot certonly \
        --webroot \
        -w /var/www/certbot \
        -d "$DOMAIN" \
        --email "$CERTBOT_EMAIL" \
        --non-interactive \
        --agree-tos \
        --no-eff-email
    fi

    if [[ ! -f "$CERT_PATH" ]]; then
      error_exit "certbot failed to obtain certificate. Check DNS and firewall."
    fi
    log "TLS certificate obtained successfully"
  else
    log "Existing TLS certificate found — skipping certbot"
  fi

  # Write full SSL nginx config (cert is now guaranteed to exist)
  cat > "$NGINX_CONF" << NGINXEOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    client_max_body_size 16m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeouts for long-running requests
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }
}
NGINXEOF

  ln -sf "$NGINX_CONF" "$NGINX_ENABLED"

  if nginx -t; then
    systemctl reload nginx
    log "nginx configured with TLS and reloaded"
  else
    error_exit "nginx configuration test failed. Check ${NGINX_CONF}"
  fi
else
  log "TLS disabled — Infisical backend exposed directly on port ${LISTEN_PORT}"
  log "Ensure your external load balancer / HAProxy handles TLS termination"
fi

# =============================================================================
# Start Docker Compose Services
# =============================================================================
header "Starting Infisical Services"

cd "$INSTALL_DIR"
log "Pulling container images..."
docker compose pull

log "Starting containers..."
docker compose up -d

# Wait for backend to become healthy
log "Waiting for Infisical backend to start..."
if [[ "$TLS_MODE" != "off" ]]; then
  HEALTH_URL="http://127.0.0.1:8080/api/status"
else
  HEALTH_URL="http://127.0.0.1:${LISTEN_PORT}/api/status"
fi
MAX_WAIT=60
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  if curl -sf "$HEALTH_URL" &> /dev/null; then
    log "Infisical backend is healthy"
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  warn "Backend did not respond within ${MAX_WAIT}s. It may still be starting up."
  warn "Check logs with: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f backend"
fi

# =============================================================================
# PostgreSQL Backup Cron
# =============================================================================
header "Configuring Database Backups"

cat > /etc/cron.d/infisical-backup << EOF
# Daily Infisical PostgreSQL backup at 2:00 AM
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 2 * * * root docker exec infisical-db pg_dump -U infisical -d infisical | gzip > ${BACKUP_DIR}/infisical-db-\$(date +\%Y\%m\%d-\%H\%M\%S).sql.gz 2>/dev/null && find ${BACKUP_DIR} -name "infisical-db-*.sql.gz" -mtime +${BACKUP_RETENTION_DAYS} -delete
EOF
chmod 644 /etc/cron.d/infisical-backup
log "Daily backup cron installed (2:00 AM, ${BACKUP_RETENTION_DAYS}-day retention)"
log "Backups stored in: ${BACKUP_DIR}"

# =============================================================================
# Post-Install Summary
# =============================================================================
header "Installation Complete"

echo -e "${BOLD}Container Status:${NC}"
cd "$INSTALL_DIR"
docker compose ps
echo ""

echo -e "${BOLD}Service Endpoints:${NC}"
echo -e "  Web UI:     ${CYAN}${SITE_URL}${NC}"
echo -e "  API Status: ${CYAN}${SITE_URL}/api/status${NC}"
echo ""

echo -e "${BOLD}Important Files:${NC}"
echo -e "  Compose:    ${CYAN}${INSTALL_DIR}/docker-compose.yml${NC}"
echo -e "  Env:        ${CYAN}${INSTALL_DIR}/.env${NC}"
echo -e "  Config:     ${CYAN}${INSTALL_DIR}/.install.conf${NC}"
echo -e "  Backups:    ${CYAN}${BACKUP_DIR}/${NC}"
if [[ "$TLS_MODE" != "off" ]]; then
  echo -e "  nginx:      ${CYAN}${NGINX_CONF}${NC}"
fi
echo ""

echo -e "${BOLD}Useful Commands:${NC}"
echo "  View logs:     docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
echo "  Restart:       docker compose -f ${INSTALL_DIR}/docker-compose.yml restart"
echo "  Stop:          docker compose -f ${INSTALL_DIR}/docker-compose.yml down"
echo "  Manual backup: docker exec infisical-db pg_dump -U infisical -d infisical | gzip > ${BACKUP_DIR}/manual-backup.sql.gz"
echo ""

echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  CRITICAL: Back up your ENCRYPTION_KEY from .env             ║${NC}"
echo -e "${RED}${BOLD}║  Without it, all secrets in the database are irrecoverable   ║${NC}"
echo -e "${RED}${BOLD}║  Store it in your password manager NOW                       ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ -z "$EXISTING_ENCRYPTION_KEY" ]]; then
  echo -e "${YELLOW}This is a fresh install. The first user to sign up at ${SITE_URL} becomes the admin.${NC}"
  echo ""
fi

log "Done. Infisical is running at ${SITE_URL}"
