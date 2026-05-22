#!/bin/sh
# restart-bff-staging.sh
# Restarts the vault-mtg-bff-staging systemd service.
# Runs ON the EC2 instance via SSM RunShellScript.

set -e

systemctl restart vault-mtg-bff-staging
echo "vault-mtg-bff-staging service restarted."
