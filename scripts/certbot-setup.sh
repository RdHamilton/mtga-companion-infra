#!/usr/bin/env bash
# certbot-setup.sh — Provision Let's Encrypt TLS certificate for MTGA Companion.
# Run ONCE on the EC2 instance after:
#   1. DNS A records are live (domain resolves to EC2 Elastic IP)
#   2. nginx is running (port 80 reachable from Internet for ACME challenge)
#
# Usage:
#   sudo bash certbot-setup.sh [domain] [email]
#   sudo bash certbot-setup.sh mtgacompanion.com admin@example.com

set -euo pipefail

DOMAIN="${1:-mtgacompanion.com}"
EMAIL="${2:-}"
CONF_DIR="/etc/nginx/conf.d"
SSL_CONF_SRC="/etc/nginx/conf.d/mtga-companion-ssl.conf"

log() { echo "[certbot] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

if [[ -z "$EMAIL" ]]; then
    echo "Usage: $0 <domain> <admin-email>"
    echo "Example: $0 mtgacompanion.com admin@example.com"
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo $0 $*"
    exit 1
fi

# ---------------------------------------------------------
# 1. Install certbot
# ---------------------------------------------------------
log "Installing certbot..."
dnf install -y certbot python3-certbot-nginx

# ---------------------------------------------------------
# 2. Verify nginx is running and port 80 is reachable
# ---------------------------------------------------------
log "Verifying nginx status..."
systemctl is-active nginx || { log "ERROR: nginx is not running. Start it first."; exit 1; }

# ---------------------------------------------------------
# 3. Obtain certificate and configure nginx (--nginx plugin handles both)
# ---------------------------------------------------------
log "Requesting certificate for $DOMAIN and www.$DOMAIN..."
mkdir -p /var/www/certbot
certbot --nginx \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --domains "${DOMAIN},www.${DOMAIN}" \
    --redirect \
    --non-interactive

log "Certificate obtained and nginx reconfigured for HTTPS."
log "HTTPS active. Verify at: https://$DOMAIN"

# ---------------------------------------------------------
# 5. Test auto-renewal
# ---------------------------------------------------------
log "Testing certbot auto-renewal (dry run)..."
certbot renew --dry-run

log "Auto-renewal configured via systemd certbot.timer."
log "Check timer status: systemctl status certbot.timer"
log ""
log "Done. Test TLS grade at: https://www.ssllabs.com/ssltest/analyze.html?d=${DOMAIN}"
