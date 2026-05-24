#!/usr/bin/env bash
# install-bff-latency-metric.sh
# Installs a systemd timer that computes the per-minute p99 of nginx
# $request_time for BFF API requests and publishes it to CloudWatch.
#
# Invocation (idempotent — safe to re-run; called from ec2-bootstrap.sh
# during instance launch, and may also be re-run manually via SSM):
#   sudo bash install-bff-latency-metric.sh <environment> <domain>
#
# Arguments:
#   environment   production | staging
#   domain        nginx server_name that certbot has annotated, e.g.
#                 api.vaultmtg.app or staging-api.vaultmtg.app. Used to
#                 anchor the access_log insertion (see "NGINX EDIT" below).
#
# Metric emitted every 60 s (only when there were requests in the window):
#   Namespace : MTGA/BFF
#   MetricName: BffP99LatencyMs
#   Dimension : Environment=<environment>
#   Unit      : Milliseconds
#
# The CloudWatch alarm BffLatencyAlarm in cloudwatch-alarms.yml takes the
# Maximum of this metric over a 5-minute window and fires when it exceeds
# BffLatencyThresholdMs (default 750).
#
# NGINX LOG FORMAT
# ----------------
# The repo's nginx config (scripts/deploy/ec2-bootstrap.sh) uses the default
# "combined" log format, which does NOT record $request_time. This script
# therefore installs a drop-in conf file that defines a "vaultmtg_timed" log
# format (combined + $request_time) and writes a SECOND access log,
# /var/log/nginx/access_timed.log, via an access_log directive inserted
# inside the certbot-managed HTTPS server block.
#
# The drop-in is /etc/nginx/conf.d/00-vaultmtg-metrics-logformat.conf
# (log_format only). The access_log directive itself must live INSIDE a
# server block — this script inserts it via a sed anchor on the
# "server_name <domain>; # managed by Certbot" line that certbot writes
# when it sets up the HTTPS vhost.
#
# NGINX EDIT — anchor + idempotency
# ---------------------------------
# Anchor line (certbot-managed, exact format):
#   "    server_name <domain>; # managed by Certbot"
# Insertion (added on the next line, indented to match):
#   "    access_log /var/log/nginx/access_timed.log vaultmtg_timed;"
# Idempotent: skips the edit if the access_log line is already present.
# Backs up the target conf to a sibling .bak.<ts> file before any
# modification. Filename detection (post-ADR-022 vs legacy) is in the
# script body below.
#
# Prerequisites:
#   - EC2 IAM role must have cloudwatch:PutMetricData permission (already
#     granted via the CloudWatchMetricsPublish policy in ec2.yml).
#   - certbot must have run against <domain> so the HTTPS vhost block
#     (with "server_name <domain>; # managed by Certbot") exists. When
#     called from ec2-bootstrap.sh this is guaranteed by ordering.

set -euo pipefail

ENVIRONMENT="${1:-production}"
DOMAIN="${2:-}"
# Fetch instance metadata via IMDSv2 (token-authenticated). IMDSv1 is disabled
# on this fleet (ec2.yml MetadataOptions.HttpTokens=required, S-21 / #2358).
IMDS_TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)
METRIC_SCRIPT=/usr/local/bin/put-bff-latency.sh
TIMED_LOG=/var/log/nginx/access_timed.log
LOGFORMAT_CONF=/etc/nginx/conf.d/00-vaultmtg-metrics-logformat.conf
METRIC_USER=mtga-metrics

log() { echo "[bff-latency-metric] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

log "Region: $REGION  Environment: $ENVIRONMENT  Domain: ${DOMAIN:-<none>}"

if [[ "$ENVIRONMENT" != "production" && "$ENVIRONMENT" != "staging" ]]; then
    echo "Usage: $0 <production|staging> <domain>"
    exit 1
fi

if [[ -z "$DOMAIN" ]]; then
    echo "Usage: $0 <production|staging> <domain>"
    echo "ERROR: <domain> is required so the nginx access_log directive can be"
    echo "       anchored on the certbot-managed 'server_name' line."
    exit 1
fi

# ----------------------------------------------------------
# 0. Create the unprivileged metrics user (idempotent)
# ----------------------------------------------------------
# Runs as a dedicated system user (not root). Needs the adm group to read
# /var/log/nginx/access_timed.log (nginx default ownership root:adm 640).
# AWS perms come from the EC2 instance role (cloudwatch:PutMetricData via IMDS).
if ! id "$METRIC_USER" &>/dev/null; then
    log "Creating system user $METRIC_USER..."
    useradd --system --no-create-home --shell /sbin/nologin "$METRIC_USER"
fi
usermod -a -G adm "$METRIC_USER"

# ----------------------------------------------------------
# 1. Install the nginx timed-log drop-in (log_format only)
# ----------------------------------------------------------
log "Installing nginx timed-log format drop-in at $LOGFORMAT_CONF..."
cat > "$LOGFORMAT_CONF" << 'NGINXCONF'
# Managed by install-bff-latency-metric.sh -- do not edit by hand.
# Adds an access log that records $request_time (in seconds) so the BFF
# latency metric publisher can compute a per-minute p99. The primary
# access log defined in mtga-companion.conf is left untouched.
log_format vaultmtg_timed '$remote_addr - $remote_user [$time_local] '
                          '"$request" $status $body_bytes_sent '
                          '"$http_referer" "$http_user_agent" rt=$request_time';
NGINXCONF

# Insert a server-level access_log directive into the certbot-managed HTTPS
# server block. The access_log directive must live inside a server block — a
# log_format defined at http level (the drop-in above) is necessary but not
# sufficient. Idempotent: skip if the access_log line is already present.
#
# Filename: fresh bootstrap writes vaultmtg.conf. The pre-rename live prod
# instance carries the legacy filename; detect whichever is present.
if [[ -f /etc/nginx/conf.d/vaultmtg.conf ]]; then
    NGINX_CONF=/etc/nginx/conf.d/vaultmtg.conf
else
    LEGACY_NAME=$(printf '%s-companion.conf' 'mtga')
    NGINX_CONF=/etc/nginx/conf.d/${LEGACY_NAME}
fi
ANCHOR="    server_name ${DOMAIN}; # managed by Certbot"
INSERT="    access_log ${TIMED_LOG} vaultmtg_timed;"

if [[ ! -f "$NGINX_CONF" ]]; then
    log "ERROR: $NGINX_CONF not found. ec2-bootstrap.sh must have written it before"
    log "       this script runs. Aborting."
    exit 1
fi

if grep -qF "$INSERT" "$NGINX_CONF"; then
    log "access_log directive already present in $NGINX_CONF -- skipping nginx edit."
elif ! grep -qF "$ANCHOR" "$NGINX_CONF"; then
    log "ERROR: anchor line not found in $NGINX_CONF:"
    log "         $ANCHOR"
    log "       certbot must have run against ${DOMAIN} and rewritten the conf"
    log "       before this installer is invoked. If you're running this manually"
    log "       on a fresh box, run certbot first."
    exit 1
else
    BACKUP="${NGINX_CONF}.bak.$(date +%s)"
    cp -a "$NGINX_CONF" "$BACKUP"
    log "Backed up $NGINX_CONF -> $BACKUP"

    # Use awk for the insertion (sed -i + escaped newline portability across
    # GNU/BSD sed is brittle on dollar-prefixed log-format names). Insert
    # INSERT on the line immediately after ANCHOR. If ANCHOR appears more
    # than once (shouldn't, but be defensive), only insert after the first.
    TMP="$(mktemp)"
    awk -v anchor="$ANCHOR" -v insert="$INSERT" '
        { print }
        !done && $0 == anchor { print insert; done = 1 }
    ' "$NGINX_CONF" > "$TMP"
    mv "$TMP" "$NGINX_CONF"
    chmod 644 "$NGINX_CONF"
    log "Inserted access_log directive after server_name ${DOMAIN} in $NGINX_CONF"
fi

if ! nginx -t; then
    log "ERROR: nginx -t failed after edit. Restoring backup."
    if [[ -n "${BACKUP:-}" && -f "$BACKUP" ]]; then
        cp -a "$BACKUP" "$NGINX_CONF"
        nginx -t || true
    fi
    exit 1
fi
systemctl reload nginx
log "nginx reloaded; vaultmtg_timed log format active and access_timed.log enabled."

# ----------------------------------------------------------
# 2. Write the metric publisher script
# ----------------------------------------------------------
log "Writing metric script to $METRIC_SCRIPT..."
cat > "$METRIC_SCRIPT" << SCRIPT
#!/usr/bin/env bash
# Computes the p99 of nginx \$request_time over the last 65 seconds from the
# timed access log and publishes it to CloudWatch in milliseconds. Emits
# nothing when there were no requests in the window (the alarm treats
# missing data as not-breaching).
set -euo pipefail

ENVIRONMENT="${ENVIRONMENT}"
# IMDSv2 token-authenticated fetch (HttpTokens=required on this fleet).
IMDS_TOKEN=\$(curl -sX PUT "http://169.254.169.254/latest/api/token" \\
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=\$(curl -s -H "X-aws-ec2-metadata-token: \$IMDS_TOKEN" \\
    http://169.254.169.254/latest/meta-data/placement/region)
TIMED_LOG="${TIMED_LOG}"
WINDOW_SECONDS=65

if [[ ! -f "\$TIMED_LOG" ]]; then
    echo "[bff-latency-metric] \$(date '+%Y-%m-%dT%H:%M:%S') timed log absent; skipping"
    exit 0
fi

# Extract request_time values (rt=...) from log lines within the window,
# convert seconds to milliseconds, sort, and take the p99 (ceil index).
P99_MS=\$(awk -v window="\$WINDOW_SECONDS" '
    BEGIN { cutoff = systime() - window }
    {
        # nginx time_local: [18/May/2026:12:34:56 +0000] -- field \$4 \$5
        ts = \$4
        gsub(/\[/, "", ts)
        split(ts, parts, /[/:T]/)
        months = "Jan:1:Feb:2:Mar:3:Apr:4:May:5:Jun:6:Jul:7:Aug:8:Sep:9:Oct:10:Nov:11:Dec:12"
        split(months, m, ":")
        mon = 0
        for (i=1; i<=24; i+=2) if (m[i] == parts[2]) { mon = m[i+1]; break }
        epoch = mktime(parts[3] " " mon " " parts[1] " " parts[4] " " parts[5] " " parts[6])
        if (epoch < cutoff) next
        # rt=<seconds> is the last field
        for (f=1; f<=NF; f++) {
            if (\$f ~ /^rt=/) {
                v = substr(\$f, 4) * 1000.0
                vals[++n] = v
            }
        }
    }
    END {
        if (n == 0) { exit 1 }   # no requests -> no metric
        # insertion sort (n is small at this traffic level)
        for (i=2; i<=n; i++) {
            key = vals[i]; j = i-1
            while (j >= 1 && vals[j] > key) { vals[j+1] = vals[j]; j-- }
            vals[j+1] = key
        }
        idx = int((n * 99 + 99) / 100)   # ceil(n * 0.99)
        if (idx < 1) idx = 1
        if (idx > n) idx = n
        printf "%.0f", vals[idx]
    }
' "\$TIMED_LOG") || {
    echo "[bff-latency-metric] \$(date '+%Y-%m-%dT%H:%M:%S') no requests in window; skipping"
    exit 0
}

aws cloudwatch put-metric-data \
    --region "\$REGION" \
    --namespace "MTGA/BFF" \
    --metric-data \
    MetricName=BffP99LatencyMs,Dimensions="[{Name=Environment,Value=\$ENVIRONMENT}]",Value="\${P99_MS}",Unit=Milliseconds

echo "[bff-latency-metric] \$(date '+%Y-%m-%dT%H:%M:%S') Published BffP99LatencyMs=\${P99_MS} (env=\${ENVIRONMENT})"
SCRIPT

chmod 755 "$METRIC_SCRIPT"

# ----------------------------------------------------------
# 3. Install the systemd service unit
# ----------------------------------------------------------
log "Installing systemd service unit..."
cat > /etc/systemd/system/put-bff-latency.service << 'UNIT'
[Unit]
Description=Publish BFF p99 latency to CloudWatch
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/put-bff-latency.sh
User=mtga-metrics
Group=mtga-metrics
StandardOutput=journal
StandardError=journal
UNIT

# ----------------------------------------------------------
# 4. Install the systemd timer unit (every 60 s)
# ----------------------------------------------------------
log "Installing systemd timer unit..."
cat > /etc/systemd/system/put-bff-latency.timer << 'TIMER'
[Unit]
Description=Run BFF latency metric publisher every 60 seconds

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
TIMER

# ----------------------------------------------------------
# 5. Enable and start the timer
# ----------------------------------------------------------
systemctl daemon-reload
systemctl enable put-bff-latency.timer
systemctl start put-bff-latency.timer

log "Timer installed."
systemctl list-timers put-bff-latency.timer --no-pager

# ----------------------------------------------------------
# 6. Smoke-test: run once immediately as the metrics user
# ----------------------------------------------------------
log "Running smoke test as $METRIC_USER..."
sudo -u "$METRIC_USER" bash "$METRIC_SCRIPT" || log "No requests yet -- metric will publish once traffic arrives."
log "Done. Verify the metric in CloudWatch:"
log "  aws cloudwatch get-metric-statistics --profile personal \\"
log "    --namespace MTGA/BFF --metric-name BffP99LatencyMs \\"
log "    --dimensions Name=Environment,Value=${ENVIRONMENT} \\"
log "    --start-time \$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-5M '+%Y-%m-%dT%H:%M:%S') \\"
log "    --end-time \$(date -u '+%Y-%m-%dT%H:%M:%S') \\"
log "    --period 300 --statistics Maximum"
