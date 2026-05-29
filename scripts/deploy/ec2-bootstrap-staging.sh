#!/bin/bash
# ec2-bootstrap-staging.sh — Bootstrap script for VaultMTG STAGING EC2 instance (Amazon Linux 2023).
# Runs once at instance launch via CloudFormation UserData stub.
# All output logged to /var/log/mtga-companion-setup.log.
#
# This script is stored in S3 and fetched by the inline UserData stub:
#   s3://mtga-companion-deploy-artifacts-staging/bootstrap/ec2-bootstrap.sh
# It is uploaded by deploy.yml before the ec2-staging CloudFormation stack is deployed.
#
# Differences from ec2-bootstrap.sh (production):
#   - Reads SSM params from /vaultmtg/app/staging/* (canonical namespace, post R-13).
#     The legacy /vaultmtg/staging/* SSM namespace is retired; do not reintroduce it.
#   - Primary BFF service name: vault-mtg-bff-staging (port 8081).
#   - Does NOT install the collocated staging secondary unit (staging IS the primary).
#   - nginx configured for staging-api.vaultmtg.app only (no api.vaultmtg.app vhost).
#     TLS via certbot (idempotency guard preserves expanded config on re-run).
#   - CloudWatch log group names: /vaultmtg/staging/bff and /vaultmtg/staging/nginx
#     (these are CloudWatch Logs group names, not SSM Parameter Store paths).
#   - Deploy bucket: mtga-companion-deploy-artifacts-staging.
#
# Shell options: errexit + pipefail, no xtrace.
# xtrace (-x) was removed because it echoes every command and its expanded
# arguments to stderr, which means decrypted SSM secret values end up in
# /var/log/mtga-companion-setup.log. The explicit log() calls below are
# sufficient for operational tracing.
set -e
set -o pipefail
exec > >(tee /var/log/mtga-companion-setup.log) 2>&1

APP_USER="mtga-companion"
BINARY_PATH="/usr/local/bin/mtga-bff-staging"
ENV_DIR="/etc/mtga-companion-staging"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

log() { echo "[setup] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

# SSM fetch helpers split by parameter type (least-capability -- mirrors PR #177
# for the production bootstrap).
#
# fetch_ssm_plain   -- for String / StringList params. Does NOT request decryption.
# fetch_ssm_secret  -- for SecureString params. Passes --with-decryption.
# require_ssm_plain / require_ssm_secret -- same split, but fail loudly if the
#   parameter is missing or empty.
#
# Callers must pick the variant that matches the parameter's actual SSM Type.
# Mixing them up either (a) needlessly requests KMS decrypt on non-secret data
# or (b) silently fails to decrypt a SecureString (AWS returns the ciphertext).
#
# Staging parameter inventory (mirrors the production layout verified in PR #177):
#   SecureString : /vaultmtg/app/staging/daemon-jwt-secret
#   String       : /vaultmtg/app/staging/ALLOWED_ORIGINS
#                  /vaultmtg/app/staging/db-secret-arn
#                  /vaultmtg/app/staging/db-endpoint
#                  /vaultmtg/app/staging/db-name
#                  /vaultmtg/app/staging/latest-bff-sha
#                  /vaultmtg/app/staging/domain-name
#                  /vaultmtg/app/staging/certbot-email

fetch_ssm_plain() {
    aws ssm get-parameter \
        --region "$REGION" \
        --name "$1" \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || true
}

fetch_ssm_secret() {
    aws ssm get-parameter \
        --region "$REGION" \
        --name "$1" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || true
}

require_ssm_plain() {
    local _name="$1"
    local _val
    _val=$(fetch_ssm_plain "$_name")
    if [ -z "$_val" ] || [ "$_val" = "None" ]; then
        log "FATAL: required SSM parameter '$_name' is missing or empty. Aborting bootstrap."
        exit 1
    fi
    printf '%s' "$_val"
}

require_ssm_secret() {
    local _name="$1"
    local _val
    _val=$(fetch_ssm_secret "$_name")
    if [ -z "$_val" ] || [ "$_val" = "None" ]; then
        log "FATAL: required SSM parameter '$_name' is missing or empty. Aborting bootstrap."
        exit 1
    fi
    printf '%s' "$_val"
}


# ---------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------
log "Updating packages..."
dnf update -y --quiet
dnf install -y nginx logrotate aws-cli jq python3 python3-pip postgresql15 amazon-cloudwatch-agent cronie
pip3 install --quiet certbot certbot-nginx
systemctl enable --now crond

# ---------------------------------------------------------
# 2. Application user and directories
# ---------------------------------------------------------
log "Creating app user..."
id "$APP_USER" &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin "$APP_USER"
mkdir -p "$(dirname "$BINARY_PATH")" "$ENV_DIR"
chmod 750 "$ENV_DIR"

# ---------------------------------------------------------
# 3. Environment file from SSM
#
# Reads from /vaultmtg/app/staging/* (staging namespace).
# ---------------------------------------------------------
log "Fetching config from SSM (/vaultmtg/app/staging/*)..."

# Port is controlled exclusively by the systemd unit's Environment=BFF_PORT=8081
# directive below. The BFF binary reads BFF_PORT only (services/bff/cmd/main.go);
# any PORT= entry in the env file would be silently ignored, so we do not fetch
# or write one here.

ALLOWED_ORIGINS=$(require_ssm_plain "/vaultmtg/app/staging/ALLOWED_ORIGINS")
# daemon-jwt-secret is optional for staging (daemon not yet deployed to staging).
# Fetch with fallback -- missing value logs a warning but does not abort bootstrap.
# SecureString param -- use the _secret variant so AWS decrypts the value.
DAEMON_JWT_SECRET=$(fetch_ssm_secret "/vaultmtg/app/staging/daemon-jwt-secret")
if [ -z "$DAEMON_JWT_SECRET" ] || [ "$DAEMON_JWT_SECRET" = "None" ]; then
    log "WARNING: /vaultmtg/app/staging/daemon-jwt-secret not set -- DAEMON_JWT_SECRET will be empty."
    DAEMON_JWT_SECRET=""
fi

# Credential-free DATABASE_URL -- BFF resolves credentials via DB_SECRET_ARN
# at startup.
DB_SECRET_ARN=$(require_ssm_plain "/vaultmtg/app/staging/db-secret-arn")
DB_ENDPOINT=$(require_ssm_plain "/vaultmtg/app/staging/db-endpoint")
DB_NAME=$(require_ssm_plain "/vaultmtg/app/staging/db-name")
DATABASE_URL="postgresql://${DB_ENDPOINT}:5432/${DB_NAME}?sslmode=require"

log "Writing env file to $ENV_DIR/env..."
{
    printf 'DATABASE_URL=%s\n'     "$DATABASE_URL"
    printf 'DB_SECRET_ARN=%s\n'    "$DB_SECRET_ARN"
    printf 'MTGA_ENV=staging\n'
    printf 'AWS_DEFAULT_REGION=%s\n' "$REGION"
    printf 'GIN_MODE=release\n'
    printf 'ALLOWED_ORIGINS=%s\n'  "$ALLOWED_ORIGINS"
    printf 'DAEMON_JWT_SECRET=%s\n' "$DAEMON_JWT_SECRET"
} > "$ENV_DIR/env"
chmod 600 "$ENV_DIR/env"
chown "root:$APP_USER" "$ENV_DIR/env"
log "Env file written successfully."

# ---------------------------------------------------------
# 4. BFF binary install
#
# Fetch the latest released staging BFF binary from S3.
# The deploy pipeline writes the deployed SHA to SSM:
#   /vaultmtg/app/staging/latest-bff-sha
# If the param is absent (pre-first-deploy), skip start.
# ---------------------------------------------------------
log "Fetching BFF binary from S3..."
DEPLOY_SHA=$(fetch_ssm_plain "/vaultmtg/app/staging/latest-bff-sha")
DEPLOY_BUCKET="mtga-companion-deploy-artifacts-staging"

if [ -n "$DEPLOY_SHA" ] && [ "$DEPLOY_SHA" != "None" ]; then
    log "Downloading mtga-bff @ ${DEPLOY_SHA} from s3://${DEPLOY_BUCKET}/releases/${DEPLOY_SHA}/mtga-bff"
    aws s3 cp \
        "s3://${DEPLOY_BUCKET}/releases/${DEPLOY_SHA}/mtga-bff" \
        "$BINARY_PATH.next" \
        --region "$REGION"
    chmod +x "$BINARY_PATH.next"
    mv "$BINARY_PATH.next" "$BINARY_PATH"
    log "BFF binary installed at $BINARY_PATH"
else
    log "WARNING: SSM /vaultmtg/app/staging/latest-bff-sha not set."
    log "Binary not installed. The next CI deploy will install and start the service."
fi

# ---------------------------------------------------------
# 5. systemd service (vault-mtg-bff-staging)
#
# On the dedicated staging EC2, the staging BFF IS the primary
# service -- it runs on port 8081 (matches live i-0226bf51fcf09b506
# config reconciled 2026-05-29; nginx proxy_pass also points to 8081).
# No secondary collocated unit is installed here.
# ---------------------------------------------------------
log "Installing systemd service (vault-mtg-bff-staging)..."
cat > /etc/systemd/system/vault-mtg-bff-staging.service <<'UNIT'
[Unit]
Description=VaultMTG BFF Staging
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtga-companion
Group=mtga-companion
ExecStart=/usr/local/bin/mtga-bff-staging
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vault-mtg-bff-staging
Environment=BFF_PORT=8081
Environment=MTGA_ENV=staging
EnvironmentFile=/etc/mtga-companion-staging/env
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable vault-mtg-bff-staging

if [ -f "$BINARY_PATH" ]; then
    log "Starting vault-mtg-bff-staging service..."
    systemctl start vault-mtg-bff-staging
    systemctl is-active vault-mtg-bff-staging && log "vault-mtg-bff-staging started successfully." || \
        log "WARNING: vault-mtg-bff-staging failed to start. Check: journalctl -u vault-mtg-bff-staging"
else
    log "Skipping service start -- binary not present (pending first CI deploy)."
fi

# ---------------------------------------------------------
# 6. nginx configuration (staging-api.vaultmtg.app only)
#
# TLS provisioning flow (idempotent across re-runs):
#
#   Fresh instance:
#     - This block writes an HTTP-only server block (port 80).
#     - Section 8 (certbot) runs: `certbot --nginx --redirect` clones the
#       port-80 server block into a port-443 HTTPS block and rewrites port 80
#       to return a 301 redirect. Certbot stores certs at
#       /etc/letsencrypt/live/<DOMAIN>/ and injects ssl_certificate /
#       ssl_certificate_key / options-ssl-nginx.conf directives automatically.
#     - After certbot: config has both port-80 (redirect) and port-443
#       (HTTPS proxy) server blocks -- matching live i-0226bf51fcf09b506.
#
#   Re-run after certbot has already run (e.g., cloud-init retry, AMI bake):
#     - The idempotency guard below detects `listen 443 ssl` in the deployed
#       file and preserves it verbatim. No overwrite, no TLS wipe.
#     - This matches the production bootstrap pattern (ec2-bootstrap.sh §6,
#       Bug 1 fix from vault-mtg-tickets#3).
#
# Cert path: /etc/letsencrypt/live/<domain>/ (domain from SSM in section 8).
#   - On the dedicated staging EC2, the cert covers staging-api.vaultmtg.app.
#   - On the shared prod EC2 (ec2-bootstrap.sh), the cert is multi-domain
#     (api.vaultmtg.app + staging-api.vaultmtg.app). This staging script is
#     for the dedicated staging instance only -- it does NOT reuse the prod cert.
#
# Rate limit zone name: `staging_api_limit` (matches live config on
#   i-0226bf51fcf09b506 post 2026-05-29 reconciliation). The previous name
#   `stg_api_limit` was a drift introduced in PR #264; corrected here.
#
# Proxy upstream: port 8081 (matches live config and systemd unit BFF_PORT=8081).
#   The previous value 8080 was incorrect; corrected here.
# ---------------------------------------------------------
STAGING_NGINX_CONF="/etc/nginx/conf.d/staging-api.vaultmtg.app.conf"

log "Configuring nginx..."

# Idempotence guard: if the deployed config already contains a certbot-
# expanded `listen 443 ssl` server block, preserve it verbatim. Overwriting
# with the port-80-only template would wipe the TLS server block (same bug
# pattern as vault-mtg-tickets#3 Bug 1 in ec2-bootstrap.sh).
if [ -f "${STAGING_NGINX_CONF}" ] && grep -q "listen 443 ssl" "${STAGING_NGINX_CONF}"; then
    log "nginx staging config already has TLS (listen 443 ssl) -- preserving deployed file."
else
    log "Writing fresh nginx staging config (no existing TLS block) -- certbot will expand."
    cat > "${STAGING_NGINX_CONF}" <<'NGINX'
# Rate limit zone -- raised from 30r/m burst=10 to 60r/m burst=50 (2026-05-29
# incident fix): the SPA fires 10+ parallel requests per page load; burst=10
# saturated immediately causing 503s. Live patch applied during incident;
# codified here so re-provision does not revert it. Applied to /api/v1/.
# /healthz and the SSE stream /api/v1/events are exempt.
# Zone name: staging_api_limit (reconciled 2026-05-29 to match live config).
limit_req_zone $binary_remote_addr zone=staging_api_limit:10m rate=60r/m;

server {
    listen 80 default_server;
    server_name staging-api.vaultmtg.app;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # CORS headers are NOT set at the server-block level.
    #
    # Rationale (2026-05-29 post-mortem, tickets#187):
    # The BFF go-chi/cors middleware adds Access-Control-Allow-Origin on every
    # proxied response. Setting CORS add_header at the server block or inside
    # location /api/v1/ causes a DUPLICATE ACAO on every proxied response.
    # Chromium rejects any response with a duplicate ACAO as a CORS violation
    # (status 0) -- breaking the SPA entirely.
    #
    # CORS headers for nginx-generated error responses (502/503/504) that bypass
    # go-chi/cors are handled by the @upstream_error named location below.
    # Certbot carries error_page and the named location through to the expanded
    # HTTPS server block on first provision.
    error_page 502 503 504 @upstream_error;

    location /api/v1/ {
        limit_req zone=staging_api_limit burst=50 nodelay;
        # No CORS add_header here -- the BFF go-chi/cors middleware handles it.
        proxy_pass         http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_read_timeout    60s;
        proxy_send_timeout    30s;
    }

    location /health {
        proxy_pass       http://127.0.0.1:8081/health;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        access_log off;
    }

    location /healthz {
        proxy_pass       http://127.0.0.1:8081/healthz;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        access_log off;
    }

    root /var/www/mtga-companion;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location ~ /\. {
        deny all;
    }

    # Named location for nginx-generated upstream errors (502/503/504).
    # The BFF never processed these requests so go-chi/cors never ran.
    # internal prevents direct client access (only reachable via error_page).
    location @upstream_error {
        internal;
        default_type application/json;
        add_header Access-Control-Allow-Origin "https://stg-app.vaultmtg.app" always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With" always;
        add_header Access-Control-Allow-Credentials "true" always;
        return 502 '{"error":"upstream_unavailable"}';
    }
}
NGINX
fi

rm -f /etc/nginx/conf.d/default.conf
mkdir -p /var/www/mtga-companion /var/www/certbot
chown -R nginx:nginx /var/www/mtga-companion /var/www/certbot

nginx -t
systemctl enable nginx
systemctl start nginx

# ---------------------------------------------------------
# 7. Log rotation
# ---------------------------------------------------------
log "Configuring logrotate..."
cat > /etc/logrotate.d/vault-mtg-bff-staging <<'LOGROTATE'
/var/log/vault-mtg-bff-staging/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl kill -s HUP vault-mtg-bff-staging || true
    endscript
}
LOGROTATE

cat > /etc/logrotate.d/mtga-bff <<'LOGROTATE'
/var/log/mtga-bff/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl kill -s HUP rsyslog || true
    endscript
}
LOGROTATE

# ---------------------------------------------------------
# 8. Certbot / Let's Encrypt
# Reads domain from SSM. Idempotent: skips if domain not set or cert exists.
# ---------------------------------------------------------
log "Checking for domain in SSM..."
DOMAIN=$(fetch_ssm_plain "/vaultmtg/app/staging/domain-name")
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "None" ]; then
    log "Domain: $DOMAIN -- running certbot..."
    CERTBOT_EMAIL=$(require_ssm_plain "/vaultmtg/app/staging/certbot-email")
    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        certbot --nginx --non-interactive --agree-tos \
            --email "$CERTBOT_EMAIL" \
            --domains "$DOMAIN" --redirect \
            2>&1 | tee /var/log/certbot-init.log || log "WARNING: certbot failed"
    else
        log "Cert already present -- skipping."
    fi
    if [ ! -f /etc/systemd/system/certbot.timer ]; then
        cat > /etc/systemd/system/certbot.service <<'CERTSVC'
[Unit]
Description=Certbot Renewal
[Service]
Type=oneshot
ExecStart=/usr/local/bin/certbot renew --quiet --nginx
PrivateTmp=true
CERTSVC
        cat > /etc/systemd/system/certbot.timer <<'CERTTIMER'
[Unit]
Description=Run certbot twice daily
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=43200
Persistent=true
[Install]
WantedBy=timers.target
CERTTIMER
        systemctl daemon-reload
    fi
    systemctl enable --now certbot.timer
    log "Certbot renewal timer enabled."
else
    log "No domain in SSM (/vaultmtg/app/staging/domain-name) -- skipping certbot."
    log "Set /vaultmtg/app/staging/domain-name to staging-api.vaultmtg.app in SSM before deploying."
fi

# ---------------------------------------------------------
# 9. BFF log forwarding via rsyslog
# ---------------------------------------------------------
log "Configuring rsyslog for BFF log forwarding..."
dnf install -y rsyslog
mkdir -p /var/log/mtga-bff
cat > /etc/rsyslog.d/mtga-bff.conf <<'RSYSLOG'
:programname, isequal, "vault-mtg-bff-staging" /var/log/mtga-bff/bff.log
& stop
RSYSLOG
systemctl enable rsyslog
systemctl restart rsyslog
log "rsyslog configured."

chown nginx:nginx /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null || true
usermod -a -G nginx cwagent 2>/dev/null || true
systemctl restart amazon-cloudwatch-agent 2>/dev/null || true

# ---------------------------------------------------------
# 10. CloudWatch Agent configuration
# Collects: CPU, memory, disk.
# Ships logs: BFF -> /vaultmtg/staging/bff
#             nginx -> /vaultmtg/staging/nginx
# ---------------------------------------------------------
log "Configuring CloudWatch Agent..."
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWCONFIG'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent"
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    },
    "metrics_collected": {
      "cpu": {
        "measurement": [
          "cpu_usage_idle",
          "cpu_usage_user",
          "cpu_usage_system"
        ],
        "metrics_collection_interval": 60,
        "totalcpu": true
      },
      "disk": {
        "measurement": [
          "disk_used_percent"
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "/"
        ],
        "ignore_file_system_types": [
          "tmpfs",
          "devtmpfs"
        ]
      },
      "mem": {
        "measurement": [
          "mem_used_percent"
        ],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/mtga-bff/bff.log",
            "log_group_name": "/vaultmtg/staging/bff",
            "log_stream_name": "{instance_id}/vault-mtg-bff-staging",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/access.log",
            "log_group_name": "/vaultmtg/staging/nginx",
            "log_stream_name": "{instance_id}/access",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/error.log",
            "log_group_name": "/vaultmtg/staging/nginx",
            "log_stream_name": "{instance_id}/error",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
CWCONFIG

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

systemctl enable amazon-cloudwatch-agent
systemctl restart amazon-cloudwatch-agent

CWA_STATUS=$(systemctl is-active amazon-cloudwatch-agent 2>/dev/null || echo unknown)
log "CloudWatch agent status: $CWA_STATUS"

log "Bootstrap complete."
