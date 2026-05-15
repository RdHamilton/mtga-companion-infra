#!/usr/bin/env bash
# install-bff-5xx-metric.sh
# Installs a systemd timer that counts HTTP 5xx responses in the nginx access log
# and publishes the count to CloudWatch every 60 seconds.
#
# Run once via SSM Session Manager:
#   sudo bash /tmp/install-bff-5xx-metric.sh [environment]
#
# Arguments:
#   environment   production (default) or staging
#
# Metric emitted every 60 s:
#   Namespace : MTGA/BFF
#   MetricName: Http5xxCount
#   Dimension : Environment=<environment>
#   Unit      : Count
#
# The CloudWatch alarm in cloudwatch-alarms.yml sums this metric over
# a 5-minute window and fires when the sum exceeds Bff5xxThreshold (default 5).
#
# Prerequisites:
#   - nginx access log at /var/log/nginx/access.log in combined log format
#   - EC2 IAM role must have cloudwatch:PutMetricData permission (already
#     granted via CloudWatchMetricsPublish policy in ec2.yml)

set -euo pipefail

ENVIRONMENT="${1:-production}"
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
METRIC_SCRIPT=/usr/local/bin/put-bff-5xx-count.sh
NGINX_ACCESS_LOG=/var/log/nginx/access.log

log() { echo "[bff-5xx-metric] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

log "Region: $REGION  Environment: $ENVIRONMENT"

# Validate environment
if [[ "$ENVIRONMENT" != "production" && "$ENVIRONMENT" != "staging" ]]; then
    echo "Usage: $0 [production|staging]"
    exit 1
fi

# ----------------------------------------------------------
# 1. Write the metric publisher script
# ----------------------------------------------------------
log "Writing metric script to $METRIC_SCRIPT..."
cat > "$METRIC_SCRIPT" << SCRIPT
#!/usr/bin/env bash
# Counts HTTP 5xx responses in the nginx access log in the past 65 seconds
# (slight overlap to avoid missing entries at the boundary) and publishes
# the count to CloudWatch.
set -euo pipefail

ENVIRONMENT="${ENVIRONMENT}"
REGION=\$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
NGINX_LOG="${NGINX_ACCESS_LOG}"
WINDOW_SECONDS=65

if [[ ! -f "\$NGINX_LOG" ]]; then
    # Log not present — emit zero so the alarm stays notBreaching.
    COUNT=0
else
    # nginx combined log format: the status code is the 9th space-separated field.
    # awk selects lines where \$9 starts with 5 (5xx) and were logged within the window.
    # We use awk's systime() to compute the cutoff epoch; this avoids a dependency on
    # GNU date --date syntax which differs between Amazon Linux and macOS.
    COUNT=\$(awk -v window="\$WINDOW_SECONDS" '
        BEGIN { cutoff = systime() - window }
        {
            # Parse nginx combined log timestamp: [18/May/2026:12:34:56 +0000]
            # Field \$4 is "[day/Mon/YYYY:HH:MM:SS"  \$5 is "+TZOFFSET]"
            ts = \$4
            gsub(/\[/, "", ts)
            split(ts, parts, /[/:T]/)
            months = "Jan:1:Feb:2:Mar:3:Apr:4:May:5:Jun:6:Jul:7:Aug:8:Sep:9:Oct:10:Nov:11:Dec:12"
            split(months, m, ":")
            mon = 0
            for (i=1; i<=24; i+=2) if (m[i] == parts[2]) { mon = m[i+1]; break }
            # mktime format: YYYY MM DD HH MM SS
            epoch = mktime(parts[3] " " mon " " parts[1] " " parts[4] " " parts[5] " " parts[6])
            if (epoch >= cutoff && \$9 ~ /^5/) count++
        }
        END { print (count+0) }
    ' "\$NGINX_LOG")
fi

aws cloudwatch put-metric-data \
    --region "\$REGION" \
    --namespace "MTGA/BFF" \
    --metric-data \
    MetricName=Http5xxCount,Dimensions="[{Name=Environment,Value=\$ENVIRONMENT}]",Value="\${COUNT}",Unit=Count

echo "[bff-5xx-metric] \$(date '+%Y-%m-%dT%H:%M:%S') Published Http5xxCount=\${COUNT} (env=\${ENVIRONMENT})"
SCRIPT

chmod 755 "$METRIC_SCRIPT"

# ----------------------------------------------------------
# 2. Install the systemd service unit
# ----------------------------------------------------------
log "Installing systemd service unit..."
cat > /etc/systemd/system/put-bff-5xx-count.service << 'UNIT'
[Unit]
Description=Publish BFF HTTP 5xx count to CloudWatch
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/put-bff-5xx-count.sh
User=root
StandardOutput=journal
StandardError=journal
UNIT

# ----------------------------------------------------------
# 3. Install the systemd timer unit (every 60 s)
# ----------------------------------------------------------
log "Installing systemd timer unit..."
cat > /etc/systemd/system/put-bff-5xx-count.timer << 'TIMER'
[Unit]
Description=Run BFF 5xx metric publisher every 60 seconds

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
TIMER

# ----------------------------------------------------------
# 4. Enable and start the timer
# ----------------------------------------------------------
systemctl daemon-reload
systemctl enable put-bff-5xx-count.timer
systemctl start put-bff-5xx-count.timer

log "Timer installed."
systemctl list-timers put-bff-5xx-count.timer --no-pager

# ----------------------------------------------------------
# 5. Smoke-test: run once immediately and verify it publishes
# ----------------------------------------------------------
log "Running smoke test..."
bash "$METRIC_SCRIPT"
log "Done. Verify the metric in CloudWatch:"
log "  aws cloudwatch get-metric-statistics --profile personal \\"
log "    --namespace MTGA/BFF --metric-name Http5xxCount \\"
log "    --dimensions Name=Environment,Value=${ENVIRONMENT} \\"
log "    --start-time \$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-5M '+%Y-%m-%dT%H:%M:%S') \\"
log "    --end-time \$(date -u '+%Y-%m-%dT%H:%M:%S') \\"
log "    --period 300 --statistics Sum"
