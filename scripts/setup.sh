#!/usr/bin/env bash
# setup.sh — Bootstrap script for MTGA Companion EC2 instance (Amazon Linux 2023)
# Run once at instance launch via CloudFormation UserData.
# Idempotent: safe to re-run.
# Covers tickets #976 (nginx+systemd) and #977 (domain+SSL via certbot).

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-production}"
APP_USER="mtga-companion"
BFF_BIN="/usr/local/bin/mtga-bff"
ENV_DIR="/etc/mtga-companion"

log() { echo "[setup] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

# ---------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------
log "Installing system packages..."
dnf update -y --quiet
dnf install -y nginx logrotate aws-cli jq python3 python3-pip

# certbot via pip (certbot-nginx not in AL2023 default repos)
pip3 install --quiet certbot certbot-nginx

# ---------------------------------------------------------
# 2. Application user
# ---------------------------------------------------------
log "Creating app user..."
id "$APP_USER" &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin "$APP_USER"
mkdir -p "$ENV_DIR"
chmod 750 "$ENV_DIR"

# ---------------------------------------------------------
# 3. Placeholder binary (real binary deployed via release pipeline + SSM)
# ---------------------------------------------------------
if [ ! -f "$BFF_BIN" ]; then
    log "Installing placeholder binary at $BFF_BIN..."
    cat > "$BFF_BIN" << 'PLACEHOLDER'
#!/bin/bash
# Placeholder — deploy the real mtga-bff binary via the release pipeline.
echo "mtga-bff placeholder — waiting for real binary"
sleep infinity
PLACEHOLDER
    chmod +x "$BFF_BIN"
fi

# ---------------------------------------------------------
# 4. Environment file from Secrets Manager + SSM
# ---------------------------------------------------------
log "Fetching runtime config from Secrets Manager and SSM..."

fetch_ssm() {
    aws ssm get-parameter \
        --region "$AWS_REGION" \
        --name "$1" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || echo ""
}

PORT=$(fetch_ssm "/mtga-companion/${ENVIRONMENT}/PORT" || echo "")
PORT="${PORT:-8080}"

# Assemble DATABASE_URL from the RDS Secrets Manager secret
DB_SECRET_ARN=$(aws cloudformation list-exports \
    --query "Exports[?Name=='mtga-companion-rds-DBSecretArn'].Value" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")

DATABASE_URL=""
if [ -n "$DB_SECRET_ARN" ] && [ "$DB_SECRET_ARN" != "None" ]; then
    DB_JSON=$(aws secretsmanager get-secret-value \
        --secret-id "$DB_SECRET_ARN" \
        --query SecretString \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "{}")
    DB_HOST=$(echo "$DB_JSON" | jq -r '.host // empty' 2>/dev/null || echo "")
    DB_PORT=$(echo "$DB_JSON" | jq -r '.port // "5432"' 2>/dev/null || echo "5432")
    DB_NAME=$(echo "$DB_JSON" | jq -r '.dbname // empty' 2>/dev/null || echo "")
    DB_USER=$(echo "$DB_JSON" | jq -r '.username // empty' 2>/dev/null || echo "")
    DB_PASS=$(echo "$DB_JSON" | jq -r '.password // empty' 2>/dev/null || echo "")
    if [ -n "$DB_HOST" ]; then
        DATABASE_URL="postgres://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require"
        log "DB credentials fetched successfully."
    else
        log "WARNING: DB_HOST empty — DATABASE_URL not set."
    fi
else
    log "WARNING: DB secret ARN not found — DATABASE_URL not set."
fi

cat > "$ENV_DIR/env" << ENV_FILE
PORT=${PORT}
DATABASE_URL=${DATABASE_URL}
ENVIRONMENT=${ENVIRONMENT}
AWS_REGION=${AWS_REGION}
GIN_MODE=release
ENV_FILE
chmod 640 "$ENV_DIR/env"
chown "root:$APP_USER" "$ENV_DIR/env"

# ---------------------------------------------------------
# 5. nginx configuration
# ---------------------------------------------------------
log "Configuring nginx..."
cp /tmp/mtga-companion.conf /etc/nginx/conf.d/mtga-companion.conf

# Remove default server block if present
rm -f /etc/nginx/conf.d/default.conf

# Frontend static asset directory and certbot webroot
mkdir -p /var/www/mtga-companion /var/www/certbot
chown -R nginx:nginx /var/www/mtga-companion

nginx -t

# ---------------------------------------------------------
# 6. systemd service
# ---------------------------------------------------------
log "Installing systemd service..."
cp /tmp/mtga-companion.service /etc/systemd/system/mtga-companion.service
systemctl daemon-reload
systemctl enable mtga-companion
systemctl enable nginx

# ---------------------------------------------------------
# 7. Log rotation
# ---------------------------------------------------------
log "Configuring log rotation..."
cat > /etc/logrotate.d/mtga-companion << 'LOGROTATE'
/var/log/mtga-companion/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl kill -s HUP mtga-companion || true
    endscript
}
LOGROTATE

# ---------------------------------------------------------
# 8. Start services
# ---------------------------------------------------------
log "Starting nginx..."
systemctl start nginx

# Start BFF service (placeholder binary will sleep until real deploy)
log "Starting mtga-companion service (placeholder)..."
systemctl start mtga-companion || true

# ---------------------------------------------------------
# 9. Certbot / Let's Encrypt — ticket #977
# Reads domain from SSM Parameter Store.
# Idempotent: skips if domain is not set or cert already exists.
# ---------------------------------------------------------
log "Checking for domain configuration in SSM..."
DOMAIN=$(fetch_ssm "/mtga-companion/${ENVIRONMENT}/domain-name" || echo "")

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "None" ]; then
    log "Domain found: $DOMAIN — obtaining Let's Encrypt certificate..."

    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        certbot --nginx \
            --non-interactive \
            --agree-tos \
            --email "ray.hamilton@stablekernel.com" \
            --domains "$DOMAIN" \
            --redirect \
            2>&1 | tee /var/log/certbot-init.log || {
                log "WARNING: certbot failed — check /var/log/certbot-init.log"
            }
    else
        log "Certificate already present for $DOMAIN — skipping issuance."
    fi

    # Auto-renewal cron (idempotent)
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --nginx && systemctl reload nginx") | crontab -
        log "Certbot renewal cron installed."
    fi
else
    log "No domain set in SSM (/mtga-companion/${ENVIRONMENT}/domain-name) — skipping certbot."
    log "Set that SSM parameter and re-run to enable HTTPS."
fi

log "Bootstrap complete."
log "  BFF binary:  $BFF_BIN (deploy real binary via release pipeline)"
log "  Service:     systemctl status mtga-companion"
log "  nginx:       systemctl status nginx"
