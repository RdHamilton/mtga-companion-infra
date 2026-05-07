#!/bin/sh
# restart-bff-staging.sh
# Restarts the mtga-companion-staging systemd service.
# Runs ON the EC2 instance via SSM RunShellScript.

set -e

systemctl restart mtga-companion-staging
echo "mtga-companion-staging service restarted."
