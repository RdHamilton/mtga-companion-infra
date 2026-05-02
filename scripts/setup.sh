#!/usr/bin/env bash
# setup.sh — Bootstrap script for MTGA Companion EC2 instance (Amazon Linux 2023)
# Run once at instance launch via CloudFormation UserData.
# Idempotent: safe to re-run.

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
APP_USER="mtga-companion"
APP_DIR="/opt/mtga-companion"
ENV_DIR="/etc/mtga-companion"
BINARY_NAME="mtga-companion-linux-amd64"

log() { echo "[setup] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

# ---------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------
log "Installing system packages..."
dnf update -y --quiet
dnf install -y nginx logrotate aws-cli jq

# ---------------------------------------------------------
# 2. Application user and directories
# ---------------------------------------------------------
log "Creating app user and directories..."
id "$APP_USER" &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin "$APP_USER"

mkdir -p "$APP_DIR/bin" "$ENV_DIR"
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chmod 750 "$ENV_DIR"

# ---------------------------------------------------------
# 3. Environment file from SSM Parameter Store
# ---------------------------------------------------------
log "Fetching runtime config from SSM Parameter Store..."
# Values are stored as SecureString parameters:
#   /mtga-companion/production/PORT
#   /mtga-companion/production/DB_URL
# The DB_URL is assembled from the Secrets Manager secret at deploy time.
SSM_PATH="/mtga-companion/production"

fetch_param() {
    aws ssm get-parameter \
        --region "$AWS_REGION" \
        --name "${SSM_PATH}/$1" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || echo ""
}

PORT=$(fetch_param "PORT")
PORT="${PORT:-8080}"
DB_URL=$(fetch_param "DB_URL")

cat > "$ENV_DIR/env" <<EOF
PORT=${PORT}
DB_URL=${DB_URL}
GIN_MODE=release
EOF
chmod 640 "$ENV_DIR/env"
chown "root:$APP_USER" "$ENV_DIR/env"

# ---------------------------------------------------------
# 4. nginx configuration
# ---------------------------------------------------------
log "Configuring nginx..."
cp /tmp/mtga-companion.conf /etc/nginx/conf.d/mtga-companion.conf

# Remove default server block if present
rm -f /etc/nginx/conf.d/default.conf

# Frontend static asset directory
mkdir -p /var/www/mtga-companion
chown -R nginx:nginx /var/www/mtga-companion

nginx -t

# ---------------------------------------------------------
# 5. systemd service
# ---------------------------------------------------------
log "Installing systemd service..."
cp /tmp/mtga-companion.service /etc/systemd/system/mtga-companion.service
systemctl daemon-reload
systemctl enable mtga-companion
systemctl enable nginx

# ---------------------------------------------------------
# 6. Log rotation
# ---------------------------------------------------------
log "Configuring log rotation..."
cat > /etc/logrotate.d/mtga-companion <<'LOGROTATE'
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
# 7. Start services
# ---------------------------------------------------------
# nginx starts immediately; mtga-companion starts after binary is deployed
log "Starting nginx..."
systemctl start nginx

log "Bootstrap complete. Deploy the application binary to start the API service."
log "  Binary path: $APP_DIR/bin/$BINARY_NAME"
log "  Service:     systemctl start mtga-companion"
