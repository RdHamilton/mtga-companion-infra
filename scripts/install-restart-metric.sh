#!/bin/bash
# install-restart-metric.sh
# Installs a systemd timer that publishes bff-staging restart counts to CloudWatch.
# Run once via SSM Session Manager:
#   sudo bash /tmp/install-restart-metric.sh
#
# Metric emitted every 60 s:
#   Namespace : MTGA/Staging
#   MetricName: BffStagingRestartCount
#   Dimension : Service=bff-staging
#
# The CloudWatch alarm in cloudwatch-alarms.yml sums this metric over
# a 5-minute window and fires when the sum exceeds 3.

set -euo pipefail

REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
METRIC_SCRIPT=/usr/local/bin/put-bff-staging-restarts.sh

log() { echo "[restart-metric] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

log "Region: $REGION"

# ----------------------------------------------------------
# 1. Write the metric publisher script
# ----------------------------------------------------------
log "Writing metric script to $METRIC_SCRIPT..."
cat > "$METRIC_SCRIPT" << SCRIPT
#!/bin/bash
# Counts bff-staging.service restarts in the past 60 seconds and
# publishes the count to CloudWatch.
set -euo pipefail

REGION=\$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
WINDOW_SECONDS=65  # slight overlap to avoid missing restarts at boundary

# journald uses the Restarting state; count transitions to it in the window
RESTART_COUNT=\$(journalctl -u bff-staging.service \
    --since "\${WINDOW_SECONDS} seconds ago" \
    --no-pager -q 2>/dev/null \
    | grep -c "bff-staging.service: Scheduled restart job" || true)

aws cloudwatch put-metric-data \
    --region "\$REGION" \
    --namespace "MTGA/Staging" \
    --metric-data \
    MetricName=BffStagingRestartCount,Dimensions="[{Name=Service,Value=bff-staging}]",Value="\${RESTART_COUNT}",Unit=Count
SCRIPT

chmod 755 "$METRIC_SCRIPT"

# ----------------------------------------------------------
# 2. Install the systemd service unit
# ----------------------------------------------------------
log "Installing systemd service unit..."
cat > /etc/systemd/system/put-bff-staging-restarts.service << 'UNIT'
[Unit]
Description=Publish bff-staging restart count to CloudWatch
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/put-bff-staging-restarts.sh
User=root
StandardOutput=journal
StandardError=journal
UNIT

# ----------------------------------------------------------
# 3. Install the systemd timer unit (every 60 s)
# ----------------------------------------------------------
log "Installing systemd timer unit..."
cat > /etc/systemd/system/put-bff-staging-restarts.timer << 'TIMER'
[Unit]
Description=Run bff-staging restart metric publisher every 60 seconds

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
systemctl enable put-bff-staging-restarts.timer
systemctl start put-bff-staging-restarts.timer

log "Timer installed."
systemctl list-timers put-bff-staging-restarts.timer --no-pager
