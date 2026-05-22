#!/bin/sh
# provision-staging-env.sh
# Renders /etc/mtga-companion-staging/env from /vaultmtg/staging/* SSM parameters.
# Runs ON the EC2 instance via SSM RunShellScript during staging deploys.
#
# The env file is consumed by the EnvironmentFile= directive in
# systemd/vault-mtg-bff-staging.service.
#
# Parameters read (all from /vaultmtg/staging/ and /mtga-companion/staging/):
#   clerk-secret-key       -> CLERK_SECRET_KEY  (SecureString)
#   PORT                   -> PORT
#   sentry-bff-dsn         -> SENTRY_DSN
#   ALLOWED_ORIGINS        -> ALLOWED_ORIGINS
#   DATABASE_URL           -> assembled from db-endpoint + db-name + Secrets Manager
#
# The DATABASE_URL assembly mirrors provision-db-url.sh but targets the staging db.

set -e

REGION=us-east-1
ENV_FILE=/etc/mtga-companion-staging/env

mkdir -p /etc/mtga-companion-staging
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

upsert() {
  KEY="$1"
  VALUE="$2"
  if grep -q "^${KEY}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$KEY" "$VALUE" >> "$ENV_FILE"
  fi
  echo "  ${KEY} provisioned."
}

echo "Provisioning /etc/mtga-companion-staging/env from SSM..."

# PORT and BFF_PORT
# The BFF binary reads BFF_PORT (not PORT) for its HTTP listen address.
# Both keys are written for compatibility; the systemd unit's inline
# Environment=BFF_PORT=8081 directive also overrides EnvironmentFile.
PORT=$(aws ssm get-parameter \
  --name "/vaultmtg/staging/PORT" \
  --region "$REGION" \
  --query Parameter.Value --output text)
upsert PORT "$PORT"
upsert BFF_PORT "$PORT"

# MTGA_ENV (always staging)
upsert MTGA_ENV "staging"

# CLERK_SECRET_KEY (SecureString)
CLERK_SECRET=$(aws ssm get-parameter \
  --name "/vaultmtg/staging/clerk-secret-key" \
  --with-decryption \
  --region "$REGION" \
  --query Parameter.Value --output text)
upsert CLERK_SECRET_KEY "$CLERK_SECRET"

# SENTRY_DSN
SENTRY_DSN=$(aws ssm get-parameter \
  --name "/vaultmtg/staging/sentry-bff-dsn" \
  --region "$REGION" \
  --query Parameter.Value --output text)
upsert SENTRY_DSN "$SENTRY_DSN"

# ALLOWED_ORIGINS
ALLOWED_ORIGINS=$(aws ssm get-parameter \
  --name "/mtga-companion/staging/ALLOWED_ORIGINS" \
  --region "$REGION" \
  --query Parameter.Value --output text)
upsert ALLOWED_ORIGINS "$ALLOWED_ORIGINS"

# DATABASE_URL — assembled from RDS secret + endpoint + db name
DB_SECRET_ARN=$(aws ssm get-parameter \
  --name "/mtga-companion/staging/db-secret-arn" \
  --region "$REGION" \
  --query Parameter.Value --output text)
DB_ENDPOINT=$(aws ssm get-parameter \
  --name "/mtga-companion/staging/db-endpoint" \
  --region "$REGION" \
  --query Parameter.Value --output text)
DB_NAME=$(aws ssm get-parameter \
  --name "/mtga-companion/staging/db-name" \
  --region "$REGION" \
  --query Parameter.Value --output text)

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ARN" \
  --region "$REGION" \
  --query SecretString --output text)

DB_USER=$(echo "$SECRET_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['username'])")
DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['password'])")

DB_PASS_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PASS")
DATABASE_URL="postgres://${DB_USER}:${DB_PASS_ENC}@${DB_ENDPOINT}:5432/${DB_NAME}?sslmode=require"
upsert DATABASE_URL "$DATABASE_URL"

chmod 600 "$ENV_FILE"
echo "Staging env file provisioned at ${ENV_FILE}"
