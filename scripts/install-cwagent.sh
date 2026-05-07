#!/bin/bash
# install-cwagent.sh
# Installs and configures the Amazon CloudWatch Agent on the EC2 instance.
# Run once via SSM Session Manager:
#   sudo bash /tmp/install-cwagent.sh
#
# The agent emits disk_used_percent for the root filesystem.
# Metric dimensions used by the CloudWatch alarm in cloudwatch-alarms.yml:
#   Namespace : CWAgent
#   MetricName: disk_used_percent
#   device    : nvme0n1p1
#   fstype    : xfs
#   path      : /

set -euo pipefail

REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

log() { echo "[cwagent-install] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

log "Region: $REGION  Instance: $INSTANCE_ID"

# ----------------------------------------------------------
# 1. Install the CloudWatch agent package
# ----------------------------------------------------------
log "Installing amazon-cloudwatch-agent..."
dnf install -y amazon-cloudwatch-agent

# ----------------------------------------------------------
# 2. Write the agent configuration
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
  }
}
CONFIG

# ----------------------------------------------------------
# 3. Start (or restart) the agent
# ----------------------------------------------------------
log "Starting CloudWatch agent..."
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

systemctl enable amazon-cloudwatch-agent
systemctl restart amazon-cloudwatch-agent

log "CloudWatch agent installed and running."
systemctl status amazon-cloudwatch-agent --no-pager
