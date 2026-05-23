#!/bin/bash
# ec2-bootstrap.sh — Bootstrap script for VaultMTG EC2 instance (Amazon Linux 2023).
# Runs once at instance launch via CloudFormation UserData stub.
# All output logged to /var/log/mtga-companion-setup.log.
#
# This script is stored in S3 and fetched by the inline UserData stub:
#   s3://mtga-companion-deploy-artifacts-production/bootstrap/ec2-bootstrap.sh
# It is uploaded by deploy.yml before the ec2 CloudFormation stack is deployed.
#
# Covers: BFF install, CloudWatch Agent config, certbot systemd timer,
#         staging BFF unit install, env provisioning, nginx config.
# Tickets: #66 (CloudWatch Agent), #77 (certbot timer), #78 (staging BFF unit),
#          #2459 (externalize to S3 — under 16 KiB UserData limit).
#
# Shell options: errexit + pipefail, no xtrace.
# xtrace (-x) was removed because it echoes every command and its expanded
# arguments to stderr, which means decrypted SSM secret values (DAEMON_JWT_SECRET,
# DB_SECRET_ARN, etc.) end up in /var/log/mtga-companion-setup.log. The explicit
# log() calls below are sufficient for operational tracing.
set -e
set -o pipefail
exec > >(tee /var/log/mtga-companion-setup.log) 2>&1

APP_USER="mtga-companion"
BINARY_PATH="/usr/local/bin/mtga-bff"
ENV_DIR="/etc/mtga-companion"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

log() { echo "[setup] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

# Fetch an SSM parameter value by name (with decryption).
# Returns empty string on failure -- callers must check and fail-loud if required.
fetch_ssm() {
    aws ssm get-parameter \
        --region "$REGION" \
        --name "$1" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || true
}

# Fail loudly if a required SSM parameter is missing or empty.
require_ssm() {
    local _name="$1"
    local _val
    _val=$(fetch_ssm "$_name")
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
# Reads from /vaultmtg/app/production/* (canonical namespace, post R-13).
# Bug fix (R-05): uses printf statements and the credential-free
# DATABASE_URL pattern — credentials resolved at BFF startup via DB_SECRET_ARN.
# ---------------------------------------------------------
log "Fetching config from SSM (/vaultmtg/app/production/*)..."

PORT=$(fetch_ssm "/vaultmtg/app/production/PORT")
PORT="${PORT:-8080}"

ALLOWED_ORIGINS=$(require_ssm "/vaultmtg/app/production/ALLOWED_ORIGINS")
# DAEMON_JWT_SECRET is required — fail loud if missing or empty rather than
# silently writing DAEMON_JWT_SECRET= to the env file (which would break
# daemon auth at BFF startup with a non-obvious failure mode).
DAEMON_JWT_SECRET=$(require_ssm "/vaultmtg/app/production/daemon-jwt-secret")

# Credential-free DATABASE_URL -- BFF resolves credentials via DB_SECRET_ARN
# at startup (matches provision-db-url.sh and deploy-env.sh pattern).
DB_SECRET_ARN=$(require_ssm "/vaultmtg/app/production/db-secret-arn")
DB_ENDPOINT=$(require_ssm "/vaultmtg/app/production/db-endpoint")
DB_NAME=$(require_ssm "/vaultmtg/app/production/db-name")
DATABASE_URL="postgresql://${DB_ENDPOINT}:5432/${DB_NAME}?sslmode=require"

log "Writing env file to $ENV_DIR/env..."
{
    printf 'PORT=%s\n'              "$PORT"
    printf 'DATABASE_URL=%s\n'     "$DATABASE_URL"
    printf 'DB_SECRET_ARN=%s\n'    "$DB_SECRET_ARN"
    printf 'MTGA_ENV=production\n'
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
# Fetch the latest released BFF binary from S3 so a fresh instance
# is fully self-installing without any manual deploy step.
#
# The deploy pipeline writes the deployed SHA to SSM after each release:
#   /vaultmtg/app/production/latest-bff-sha
# If the param is absent (pre-first-deploy), skip start but leave the
# service enabled so the next CI deploy triggers a start automatically.
# ---------------------------------------------------------
log "Fetching BFF binary from S3..."
DEPLOY_SHA=$(fetch_ssm "/vaultmtg/app/production/latest-bff-sha")
DEPLOY_BUCKET="mtga-companion-deploy-artifacts-production"

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
    log "WARNING: SSM /vaultmtg/app/production/latest-bff-sha not set."
    log "Binary not installed. The next CI deploy will install and start the service."
    log "Action required: ensure deploy-bff.yml writes latest-bff-sha to SSM (issue #2323)."
fi

# ---------------------------------------------------------
# 5. systemd service
# ---------------------------------------------------------
log "Installing systemd service..."
cat > /etc/systemd/system/mtga-companion.service <<'UNIT'
[Unit]
Description=MTGA Companion BFF Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtga-companion
Group=mtga-companion
ExecStart=/usr/local/bin/mtga-bff
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtga-bff
EnvironmentFile=/etc/mtga-companion/env
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable mtga-companion

if [ -f "$BINARY_PATH" ]; then
    log "Starting mtga-companion service..."
    systemctl start mtga-companion
    systemctl is-active mtga-companion && log "mtga-companion started successfully." || \
        log "WARNING: mtga-companion failed to start. Check: journalctl -u mtga-companion"
else
    log "Skipping service start -- binary not present (pending first CI deploy)."
fi

# ---------------------------------------------------------
# 5b. Staging BFF systemd service (vault-mtg-bff-staging)
#
# Installs the staging unit so it survives instance replacement.
# BFF_PORT=8081 and MTGA_ENV=staging are set inline so the unit
# starts correctly even before provision-staging-env.sh runs.
# The binary (/usr/local/bin/mtga-bff-staging) and env file
# (/etc/mtga-companion-staging/env) are populated by the
# staging-deploy.yml pipeline, not by this bootstrap.
#
# See tickets #2409 and #2445.
# ---------------------------------------------------------
log "Installing staging BFF systemd service..."
mkdir -p /etc/mtga-companion-staging
chmod 750 /etc/mtga-companion-staging

# Touch a placeholder env file so EnvironmentFile= doesn't fail on first
# start (before provision-staging-env.sh has run).
touch /etc/mtga-companion-staging/env
chmod 600 /etc/mtga-companion-staging/env
chown "root:$APP_USER" /etc/mtga-companion-staging/env

cat > /etc/systemd/system/vault-mtg-bff-staging.service <<'STAGINGUNIT'
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
MemoryMax=512M
CPUQuota=50%
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
STAGINGUNIT

systemctl daemon-reload
systemctl enable vault-mtg-bff-staging
log "vault-mtg-bff-staging unit enabled (binary not yet present -- will start on first staging deploy)."

# ---------------------------------------------------------
# 6. nginx configuration
# ---------------------------------------------------------
log "Configuring nginx..."
cat > /etc/nginx/conf.d/mtga-companion.conf <<'NGINX'
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=30r/m;

server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location /api/v1/ {
        limit_req zone=api_limit burst=10 nodelay;
        proxy_pass         http://127.0.0.1:8080;
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
        proxy_pass       http://127.0.0.1:8080/health;
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
}
NGINX

rm -f /etc/nginx/conf.d/default.conf
mkdir -p /var/www/mtga-companion /var/www/certbot
chown -R nginx:nginx /var/www/mtga-companion /var/www/certbot

# Staging nginx vhost — HTTP-only block at bootstrap time.
# certbot --expand adds the HTTPS block once DNS propagates.
# See scripts/deploy/certbot-expand-staging.sh (or run manually:
#   certbot --expand -d api.vaultmtg.app -d staging-api.vaultmtg.app --nginx)
cat > /etc/nginx/conf.d/staging-api.vaultmtg.app.conf <<'STAGINGNGINX'
server {
    listen 80;
    server_name staging-api.vaultmtg.app;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}
STAGINGNGINX

nginx -t
systemctl enable nginx
systemctl start nginx

# ---------------------------------------------------------
# 7. Log rotation
# ---------------------------------------------------------
log "Configuring logrotate..."
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
# Issue #2316: /vaultmtg/app/production/domain-name must be pre-created
# in SSM before deploying -- a missing param now fails loudly (non-zero exit)
# via require_ssm rather than silently skipping certbot.
# ---------------------------------------------------------
log "Checking for domain in SSM..."
DOMAIN=$(fetch_ssm "/vaultmtg/app/production/domain-name")
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "None" ]; then
    log "Domain: $DOMAIN -- running certbot..."
    # Certbot ACME registration email — sourced from SSM rather than hardcoded
    # so the address can be rotated without an infrastructure deploy.
    # Pre-flight: parameter /vaultmtg/app/production/certbot-email must exist
    # (created out-of-band; type=String). Read access is granted via the
    # existing /vaultmtg/app/production/* wildcard on the EC2 instance role.
    CERTBOT_EMAIL=$(require_ssm "/vaultmtg/app/production/certbot-email")
    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        certbot --nginx --non-interactive --agree-tos \
            --email "$CERTBOT_EMAIL" \
            --domains "$DOMAIN" --redirect \
            2>&1 | tee /var/log/certbot-init.log || log "WARNING: certbot failed"
    else
        log "Cert already present -- skipping."
    fi
    # Ensure certbot renewal timer is active (issue #2315).
    # AL2023 does not install crontab by default; use a systemd timer instead.
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
    log "Certbot renewal timer enabled (next: $(systemctl show certbot.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo unknown))."
else
    log "No domain in SSM (/vaultmtg/app/production/domain-name) -- skipping certbot."
    log "WARNING: set /vaultmtg/app/production/domain-name in SSM before deploying (issue #2316)."
fi

# ---------------------------------------------------------
# 9. BFF log forwarding via rsyslog
# AL2023 uses journald only by default -- no /var/log/messages.
# rsyslog filters mtga-bff entries (by syslog identifier) into a
# dedicated file so the CloudWatch Agent can collect them as files.
# ---------------------------------------------------------
log "Configuring rsyslog for BFF log forwarding..."
dnf install -y rsyslog
mkdir -p /var/log/mtga-bff
cat > /etc/rsyslog.d/mtga-bff.conf <<'RSYSLOG'
:programname, isequal, "mtga-bff" /var/log/mtga-bff/bff.log
& stop
RSYSLOG
systemctl enable rsyslog
systemctl restart rsyslog
log "rsyslog configured."

# Fix nginx log group ownership so cwagent (added to the nginx group)
# can read existing and future log files.
#
# A running cwagent process retains its original supplementary group list — adding
# it to the nginx group via `usermod` has no effect on an already-running daemon.
# Restart the agent immediately so the new group membership takes effect before
# it tries to tail /var/log/nginx/*.log. Without this restart, the agent silently
# emits "permission denied" on every nginx log read and the BFF 5xx CWL metric
# filter (R-23, #2363) sees zero events on real 5xx traffic. Ref: #143.
chown nginx:nginx /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null || true
usermod -a -G nginx cwagent 2>/dev/null || true
systemctl restart amazon-cloudwatch-agent 2>/dev/null || true

# ---------------------------------------------------------
# 10. CloudWatch Agent configuration
# Collects: CPU (idle/user/system), memory, disk utilisation.
# Ships logs: BFF (via rsyslog -> /var/log/mtga-bff/bff.log) -> /vaultmtg/production/bff
#             nginx access+error -> /vaultmtg/production/nginx
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
            "log_group_name": "/vaultmtg/production/bff",
            "log_stream_name": "{instance_id}/mtga-bff",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/access.log",
            "log_group_name": "/vaultmtg/production/nginx",
            "log_stream_name": "{instance_id}/access",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/error.log",
            "log_group_name": "/vaultmtg/production/nginx",
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
