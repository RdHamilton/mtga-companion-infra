#!/usr/bin/env bash
# install-restart-metric-production.sh
# Installs a systemd timer that publishes production BFF restart counts to CloudWatch.
# Run once via SSM Session Manager:
#   sudo bash /tmp/install-restart-metric-production.sh
#
# Metric emitted every 60 s:
#   Namespace : MTGA/BFF
#   MetricName: BffRestartCount
#   Dimension : Environment=production
#   Unit      : Count
#
# The CloudWatch alarm BffRestartAlarm in cloudwatch-alarms.yml sums this
# metric over a 5-minute window and fires when the sum exceeds
# BffRestartCountThreshold (default 3).
#
# IMPORTANT -- unit name: the production BFF runs as the systemd unit
# "mtga-companion.service" (binary /usr/local/bin/mtga-bff), created by
# scripts/deploy/ec2-bootstrap.sh. Issue #2331 referred to it as
# "vault-mtg-bff.service"; this script tracks the REAL unit name so the
# metric is not silently always-zero.
#
# Prerequisites:
#   - EC2 IAM role must have cloudwatch:PutMetricData permission (already
#     granted via the CloudWatchMetricsPublish policy in ec2.yml).

set -euo pipefail

BFF_UNIT="mtga-companion.service"
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
METRIC_SCRIPT=/usr/local/bin/put-bff-restarts.sh

log() { echo "[bff-restart-metric] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

log "Region: $REGION  Unit: $BFF_UNIT"

# ----------------------------------------------------------
# 1. Write the metric publisher script
# ----------------------------------------------------------
log "Writing metric script to $METRIC_SCRIPT..."
cat > "$METRIC_SCRIPT" << SCRIPT
#!/usr/bin/env bash
# Counts mtga-companion.service restarts in the past 65 seconds
# (slight overlap to avoid missing restarts at the boundary) and
# publishes the count to CloudWatch.
set -euo pipefail

REGION=\$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
BFF_UNIT="${BFF_UNIT}"
WINDOW_SECONDS=65

# journald logs a "Scheduled restart job" line each time systemd restarts the
# unit (Restart=on-failure). Count those transitions within the window.
RESTART_COUNT=\$(journalctl -u "\$BFF_UNIT" \
    --since "\${WINDOW_SECONDS} seconds ago" \
    --no-pager -q 2>/dev/null \
    | grep -c "Scheduled restart job" || true)

aws cloudwatch put-metric-data \
    --region "\$REGION" \
    --namespace "MTGA/BFF" \
    --metric-data \
    MetricName=BffRestartCount,Dimensions="[{Name=Environment,Value=production}]",Value="\${RESTART_COUNT}",Unit=Count

echo "[bff-restart-metric] \$(date '+%Y-%m-%dT%H:%M:%S') Published BffRestartCount=\${RESTART_COUNT}"
SCRIPT

chmod 755 "$METRIC_SCRIPT"

# ----------------------------------------------------------
# 2. Install the systemd service unit
# ----------------------------------------------------------
log "Installing systemd service unit..."
cat > /etc/systemd/system/put-bff-restarts.service << 'UNIT'
[Unit]
Description=Publish production BFF restart count to CloudWatch
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/put-bff-restarts.sh
User=root
StandardOutput=journal
StandardError=journal
UNIT

# ----------------------------------------------------------
# 3. Install the systemd timer unit (every 60 s)
# ----------------------------------------------------------
log "Installing systemd timer unit..."
cat > /etc/systemd/system/put-bff-restarts.timer << 'TIMER'
[Unit]
Description=Run production BFF restart metric publisher every 60 seconds

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
systemctl enable put-bff-restarts.timer
systemctl start put-bff-restarts.timer

log "Timer installed."
systemctl list-timers put-bff-restarts.timer --no-pager

# ----------------------------------------------------------
# 5. Smoke-test: run once immediately and verify it publishes
# ----------------------------------------------------------
log "Running smoke test..."
bash "$METRIC_SCRIPT"
log "Done. Verify the metric in CloudWatch:"
log "  aws cloudwatch get-metric-statistics --profile personal \\"
log "    --namespace MTGA/BFF --metric-name BffRestartCount \\"
log "    --dimensions Name=Environment,Value=production \\"
log "    --start-time \$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-5M '+%Y-%m-%dT%H:%M:%S') \\"
log "    --end-time \$(date -u '+%Y-%m-%dT%H:%M:%S') \\"
log "    --period 300 --statistics Sum"
