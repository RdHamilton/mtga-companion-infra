#!/usr/bin/env bash
# check-origins-completeness.sh
#
# Asserts that every active CloudFront hostname for VaultMTG appears in the
# ALLOWED_ORIGINS SSM parameter. A mismatch means a domain was added to
# CloudFront (or removed from ALLOWED_ORIGINS) without updating the other
# surface, which was the root cause of the 2026-05-30 prod config-drift
# incident (vault-mtg-tickets#269).
#
# Usage (deploy-bff.yml post-deploy step):
#   ENVIRONMENT=production ./check-origins-completeness.sh
#
# Exit codes:
#   0 — all CloudFront hostnames appear in ALLOWED_ORIGINS
#   1 — one or more hostnames are missing (mismatch detected)
#
# RULE-INFRA-01: deploy-bff.yml runs this with continue-on-error: true until
# one full staging+prod cycle confirms no false positives. The WARNING log is
# always emitted on mismatch regardless of whether the step fails the job.
#
# AWS credentials are resolved from the runner environment (OIDC role in CI;
# instance profile on EC2). The script does not call --with-decryption — both
# ALLOWED_ORIGINS and the CloudFront distribution list are non-secret.

set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-production}"
REGION="${AWS_REGION:-us-east-1}"
SSM_PATH="/vaultmtg/app/${ENVIRONMENT}/ALLOWED_ORIGINS"

echo "[origins-check] Environment: ${ENVIRONMENT}"
echo "[origins-check] SSM path: ${SSM_PATH}"

# Fetch the current ALLOWED_ORIGINS value from SSM.
if ! ALLOWED_ORIGINS_VALUE=$(aws ssm get-parameter \
  --name "${SSM_PATH}" \
  --region "${REGION}" \
  --query "Parameter.Value" \
  --output text 2>&1); then
  echo "[origins-check] ERROR: failed to read ${SSM_PATH} from SSM: ${ALLOWED_ORIGINS_VALUE}" >&2
  exit 1
fi

echo "[origins-check] ALLOWED_ORIGINS = ${ALLOWED_ORIGINS_VALUE}"

# Fetch active VaultMTG CloudFront distribution aliases.
# Filter by aliases that contain "vaultmtg.app" to exclude rhamiltoneng.com
# and any other distributions on the account.
if ! CF_ALIASES=$(aws cloudfront list-distributions \
  --region us-east-1 \
  --query "DistributionList.Items[].Aliases.Items[]" \
  --output json 2>&1); then
  echo "[origins-check] ERROR: failed to list CloudFront distributions: ${CF_ALIASES}" >&2
  exit 1
fi

# Extract vaultmtg.app aliases as one per line (no jq -r array join needed).
VAULTMTG_ALIASES=$(echo "${CF_ALIASES}" | \
  python3 -c "import sys,json; aliases=json.load(sys.stdin); print('\n'.join(a for a in aliases if 'vaultmtg.app' in a))")

echo "[origins-check] Active CloudFront aliases (vaultmtg.app):"
echo "${VAULTMTG_ALIASES}"

# Assert each hostname appears in ALLOWED_ORIGINS (as https://<hostname>).
MISSING=()
while IFS= read -r alias; do
  [ -z "${alias}" ] && continue
  EXPECTED="https://${alias}"
  if ! echo "${ALLOWED_ORIGINS_VALUE}" | grep -qF "${EXPECTED}"; then
    MISSING+=("${EXPECTED}")
  fi
done <<< "${VAULTMTG_ALIASES}"

if [ ${#MISSING[@]} -eq 0 ]; then
  echo "[origins-check] PASS: all CloudFront hostnames present in ALLOWED_ORIGINS"
  exit 0
else
  echo "[origins-check] WARNING: the following CloudFront hostnames are MISSING from ALLOWED_ORIGINS:"
  for m in "${MISSING[@]}"; do
    echo "[origins-check]   MISSING: ${m}"
  done
  echo "[origins-check] ACTION REQUIRED: update /vaultmtg/app/${ENVIRONMENT}/ALLOWED_ORIGINS via a"
  echo "[origins-check]   CFN changeset in this repo (vault-mtg-tickets#269)."
  exit 1
fi
