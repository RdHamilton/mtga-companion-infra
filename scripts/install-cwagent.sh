#!/bin/bash
# install-cwagent.sh
# Installs and configures the Amazon CloudWatch Agent on the EC2 instance.
# Run via SSM RunCommand (AWS-RunShellScript) targeting the production EC2.
#
# Mirrors the config embedded in ec2.yml UserData sections 9 and 10 so existing
# instances receive the same configuration as fresh instances provisioned via
# CloudFormation.
#
# AL2023 does not ship rsyslog by default (pure journald). This script installs
# rsyslog to forward BFF journal entries (SyslogIdentifier=mtga-bff) to the file
# /var/log/mtga-bff/bff.log, which the CloudWatch Agent then collects.
#
# Metrics emitted (namespace: CWAgent):
#   cpu_usage_idle / cpu_usage_user / cpu_usage_system  (cpu_type=cpu-total)
#   disk_used_percent  (device=nvme0n1p1, fstype=xfs, path=/)
#   mem_used_percent
#
# Log streams created:
#   /vaultmtg/production/bff   {instance_id}/mtga-bff  (via rsyslog from journal)
#   /vaultmtg/production/nginx {instance_id}/access     (/var/log/nginx/access.log)
#   /vaultmtg/production/nginx {instance_id}/error      (/var/log/nginx/error.log)

set -euo pipefail

REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

log() { echo "[cwagent-install] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

log "Region: $REGION  Instance: $INSTANCE_ID"

# ----------------------------------------------------------
# 1. Install packages
# ----------------------------------------------------------
log "Installing amazon-cloudwatch-agent and rsyslog..."
dnf install -y amazon-cloudwatch-agent rsyslog

# ----------------------------------------------------------
# 2. Configure rsyslog to forward BFF journal entries to file
# ----------------------------------------------------------
log "Configuring rsyslog for BFF log forwarding..."
mkdir -p /var/log/mtga-bff
cat > /etc/rsyslog.d/mtga-bff.conf << 'RSYSLOG'
:programname, isequal, "mtga-bff" /var/log/mtga-bff/bff.log
& stop
RSYSLOG

systemctl enable rsyslog
systemctl restart rsyslog
log "rsyslog configured."

# ----------------------------------------------------------
# 2b. Fix log file permissions for cwagent user
# ----------------------------------------------------------
# nginx writes logs as root:root on AL2023; change group to nginx so that
# cwagent (added to the nginx group) can read via the group read bit.
chown nginx:nginx /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null || true
usermod -a -G nginx cwagent 2>/dev/null || true
# BFF log dir is owned by cwagent (group-read)
chown root:cwagent /var/log/mtga-bff /var/log/mtga-bff/bff.log 2>/dev/null || true
chmod 750 /var/log/mtga-bff 2>/dev/null || true
chmod 640 /var/log/mtga-bff/bff.log 2>/dev/null || true
log "Log permissions fixed."

# ----------------------------------------------------------
# 2c. Configure logrotate for /var/log/mtga-bff/*.log
# ----------------------------------------------------------
log "Configuring logrotate for BFF logs..."
cat > /etc/logrotate.d/mtga-bff << 'LOGROTATE'
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
log "logrotate configured for /var/log/mtga-bff/*.log."

# ----------------------------------------------------------
# 3. Write the CloudWatch Agent configuration
# ----------------------------------------------------------
log "Writing CWAgent config..."
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CONFIG'
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
CONFIG

# ----------------------------------------------------------
# 4. Start (or restart) the agent
# ----------------------------------------------------------
log "Starting CloudWatch agent..."

# Clean any stale config from previous runs to avoid parse errors
rm -f /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d/*.json \
       /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d/*.tmp

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

systemctl enable amazon-cloudwatch-agent
systemctl restart amazon-cloudwatch-agent

log "CloudWatch agent installed and running."
systemctl status amazon-cloudwatch-agent --no-pager
