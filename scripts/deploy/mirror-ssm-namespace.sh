#!/bin/sh
# mirror-ssm-namespace.sh
# Phase 1 of R-13 SSM namespace cutover.
#
# Creates /vaultmtg/app/{production,staging}/* mirrors of all BFF parameters
# currently under /mtga-companion/*. Normalizes the env segment (prod -> production).
# De-duplicates casing variants (mirrors only SCREAMING_SNAKE_CASE form of CLERK_SECRET_KEY).
#
# Old paths are NOT modified or deleted - they remain in place during the cutover
# window. Phase 6 (deletion) runs only after all consumers have been verified reading
# from the new paths.
#
# OQ-3 resolution: /mtga-companion/prod/daemon-jwt-secret is authoritative
#   (values differ between root and prod/ variants; prod/ is the env-scoped one
#   read by ec2.yml UserData).
#
# OQ-2 resolution: staging CLERK_SECRET_KEY values DIFFER between casing variants.
#   /mtga-companion/staging/CLERK_SECRET_KEY is the authoritative form (matches
#   what provision-staging-env.sh reads via $SSM_STAGING_CLERK_SECRET_KEY).
#
# Usage (run from developer workstation - NOT on EC2):
#   AWS_PROFILE=personal sh scripts/deploy/mirror-ssm-namespace.sh [--dry-run]
#
# Idempotent: put-parameter --overwrite re-writes if the parameter already exists
# with the same value, which is safe.

set -e

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  echo "[DRY-RUN] No writes will be performed."
fi

REGION="us-east-1"
PROFILE="${AWS_PROFILE:-personal}"

put_param() {
  SRC_PATH="$1"
  DST_PATH="$2"
  TYPE="$3"   # String or SecureString

  VAL=$(aws ssm get-parameter \
    --name "$SRC_PATH" \
    --with-decryption \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query "Parameter.Value" \
    --output text 2>&1)

  if [ -z "$VAL" ] || [ "$VAL" = "None" ]; then
    echo "ERROR: source parameter '$SRC_PATH' is empty or missing - skipping." >&2
    return 1
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY-RUN] put-parameter: $SRC_PATH -> $DST_PATH (Type: $TYPE)"
    return 0
  fi

  aws ssm put-parameter \
    --name "$DST_PATH" \
    --value "$VAL" \
    --type "$TYPE" \
    --overwrite \
    --region "$REGION" \
    --profile "$PROFILE" \
    --output text > /dev/null

  echo "  MIRRORED: $SRC_PATH  ->  $DST_PATH"
}

echo "=== R-13 Phase 1: Mirror /mtga-companion/* -> /vaultmtg/app/{env}/* ==="
echo "Region: $REGION  Profile: $PROFILE"
echo ""

# -----------------------------------------------------------------------------
# PRODUCTION parameters
# Source: /mtga-companion/production/*
# Source: /mtga-companion/prod/daemon-jwt-secret  (authoritative per OQ-3)
# Target: /vaultmtg/app/production/*
# -----------------------------------------------------------------------------
echo "--- Production ---"

put_param \
  "/mtga-companion/production/ALLOWED_ORIGINS" \
  "/vaultmtg/app/production/ALLOWED_ORIGINS" \
  "String"

put_param \
  "/mtga-companion/production/CLERK_FRONTEND_API" \
  "/vaultmtg/app/production/CLERK_FRONTEND_API" \
  "String"

# OQ-2 production: CLERK_SECRET_KEY casing variants are IDENTICAL in production.
# Mirror only the SCREAMING_SNAKE_CASE form.
put_param \
  "/mtga-companion/production/CLERK_SECRET_KEY" \
  "/vaultmtg/app/production/CLERK_SECRET_KEY" \
  "SecureString"

put_param \
  "/mtga-companion/production/db-endpoint" \
  "/vaultmtg/app/production/db-endpoint" \
  "String"

put_param \
  "/mtga-companion/production/db-name" \
  "/vaultmtg/app/production/db-name" \
  "String"

put_param \
  "/mtga-companion/production/db-secret-arn" \
  "/vaultmtg/app/production/db-secret-arn" \
  "String"

put_param \
  "/mtga-companion/production/domain-name" \
  "/vaultmtg/app/production/domain-name" \
  "String"

# PORT is not present under /mtga-companion/production/ in the live tree.
# The BFF defaults to 8080 when PORT is absent. Skip unless added explicitly.
# (noted in issue body - no /mtga-companion/production/PORT exists)

# OQ-3: /mtga-companion/prod/daemon-jwt-secret is authoritative (values differ
# between root /mtga-companion/daemon-jwt-secret and /mtga-companion/prod/daemon-jwt-secret).
# Mirror the prod/ form; do NOT mirror the root-level one.
put_param \
  "/mtga-companion/prod/daemon-jwt-secret" \
  "/vaultmtg/app/production/daemon-jwt-secret" \
  "SecureString"

# BFF runtime paths already under /vaultmtg/prod/* - NOT moved (owned by Greg/Faye/marketing).
# The BFF reads sentry-bff-dsn and posthog-api-key from /vaultmtg/prod/* as-is.
# These are NOT migrated to /vaultmtg/app/production/* - they remain at their current paths.
# IAM grant on the ec2 instance role retains read access to these two specific paths.
echo ""

# -----------------------------------------------------------------------------
# STAGING parameters
# Source: /mtga-companion/staging/*
# Target: /vaultmtg/app/staging/*
# -----------------------------------------------------------------------------
echo "--- Staging ---"

put_param \
  "/mtga-companion/staging/ALLOWED_ORIGINS" \
  "/vaultmtg/app/staging/ALLOWED_ORIGINS" \
  "String"

put_param \
  "/mtga-companion/staging/CLERK_FRONTEND_API" \
  "/vaultmtg/app/staging/CLERK_FRONTEND_API" \
  "SecureString"

put_param \
  "/mtga-companion/staging/CLERK_PUBLISHABLE_KEY" \
  "/vaultmtg/app/staging/CLERK_PUBLISHABLE_KEY" \
  "SecureString"

# OQ-2 staging: CLERK_SECRET_KEY casing variants DIFFER between the two forms.
# /mtga-companion/staging/CLERK_SECRET_KEY is authoritative - it matches
# /vaultmtg/staging/CLERK_SECRET_KEY (the path provision-staging-env.sh reads
# via $SSM_STAGING_CLERK_SECRET_KEY). Mirror only this form.
put_param \
  "/mtga-companion/staging/CLERK_SECRET_KEY" \
  "/vaultmtg/app/staging/CLERK_SECRET_KEY" \
  "SecureString"

put_param \
  "/mtga-companion/staging/database-url" \
  "/vaultmtg/app/staging/database-url" \
  "SecureString"

put_param \
  "/mtga-companion/staging/db-endpoint" \
  "/vaultmtg/app/staging/db-endpoint" \
  "String"

put_param \
  "/mtga-companion/staging/db-name" \
  "/vaultmtg/app/staging/db-name" \
  "String"

put_param \
  "/mtga-companion/staging/db-password" \
  "/vaultmtg/app/staging/db-password" \
  "SecureString"

put_param \
  "/mtga-companion/staging/db-secret-arn" \
  "/vaultmtg/app/staging/db-secret-arn" \
  "String"

put_param \
  "/mtga-companion/staging/PORT" \
  "/vaultmtg/app/staging/PORT" \
  "String"

echo ""
echo "=== Mirror complete. Old paths are retained - do NOT delete until Phase 6. ==="
echo "Next: run dry-run of consumer cutover (Phase 2), then open the production deploy PR."
