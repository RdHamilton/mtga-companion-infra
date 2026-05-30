#!/bin/bash
# ec2-bootstrap-selftest.sh — Offline-deterministic dry-run harness for
# ec2-bootstrap.sh. Stands up a tmpdir mock filesystem, stubs the `aws`
# CLI and the deploy-side provision scripts, runs the bootstrap in
# --dry-run mode, and asserts the four target behaviours:
#
#   ASSERTION 3 — section 2 migration: legacy /etc/mtga-companion as a
#                 real directory is migrated to /etc/vaultmtg and
#                 replaced with a symlink.
#   ASSERTION 4 — section 3b env file contains CLERK_SECRET_KEY after
#                 the deploy-side overlay runs against the stubbed
#                 provision-env.sh.
#   ASSERTION 5 — section 6 preserves an existing nginx config with a
#                 `listen 443 ssl` block (TLS preserved).
#   ASSERTION 6 — section 6 writes a fresh port-80 template into an
#                 empty nginx conf.d dir.
#
# Background: the harness exists to support the Local Verification
# transcript on vault-mtg-tickets#3 (Window B third-fix). It is the
# offline substitute for a staging EC2 deploy (Phase A established no
# *-ec2-staging stack exists in this account).
#
# Usage:
#   bash scripts/deploy/ec2-bootstrap-selftest.sh
#   # Exits 0 on all assertions PASS, 1 on first FAIL.
#
# Each assertion runs in an isolated tmpdir to keep failure modes
# independent. The harness preserves the tmpdir on FAIL for inspection.
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/ec2-bootstrap.sh"

if [ ! -f "$BOOTSTRAP" ]; then
    echo "FAIL: bootstrap script not found at $BOOTSTRAP"
    exit 1
fi

# Trap to leave tmpdirs around on failure for forensic inspection.
KEEP_TMPDIRS=0
TMPDIRS=()

cleanup() {
    if [ "$KEEP_TMPDIRS" = "0" ]; then
        for d in "${TMPDIRS[@]}"; do
            rm -rf "$d"
        done
    else
        echo ""
        echo "[selftest] preserving tmpdirs for inspection:"
        for d in "${TMPDIRS[@]}"; do
            echo "  $d"
        done
    fi
}
trap cleanup EXIT

# make_fixture <name> — creates a tmpdir mock filesystem, writes stub
# scripts and `aws` CLI, and echoes the tmpdir path on stdout. The
# caller exports BOOTSTRAP_PREFIX=<tmpdir> + PATH=<tmpdir>/usr/local/bin:$PATH
# before invoking the bootstrap.
make_fixture() {
    local name="$1"
    local d
    d="$(mktemp -d -t "ec2bootstrap-${name}.XXXXXX")"
    TMPDIRS+=("$d")

    # Mock filesystem layout
    mkdir -p \
        "${d}/etc/nginx/conf.d" \
        "${d}/etc/systemd/system" \
        "${d}/var/www" \
        "${d}/var/log" \
        "${d}/usr/local/bin" \
        "${d}/tmp"

    # Stub `aws` CLI. The bootstrap calls:
    #   aws ssm get-parameter --name <name> [--with-decryption] --query ... --output text
    # The stub responds with deterministic values keyed off the parameter name.
    cat > "${d}/usr/local/bin/aws" <<'AWSSTUB'
#!/bin/bash
# Stub `aws` CLI for ec2-bootstrap-selftest.
# Recognises the calls the bootstrap makes during sections 3 / 3b / 6.
case "$1 $2" in
    "ssm get-parameter")
        # Locate --name <value> in argv
        NAME=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --name) NAME="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        case "$NAME" in
            "/vaultmtg/app/production/ALLOWED_ORIGINS")    echo "https://app.vaultmtg.app" ;;
            "/vaultmtg/app/production/daemon-jwt-secret")  echo "STUB_DAEMON_JWT_SECRET" ;;
            "/vaultmtg/app/production/db-secret-arn")      echo "arn:aws:secretsmanager:us-east-1:000000000000:secret:stub" ;;
            "/vaultmtg/app/production/db-endpoint")        echo "stub-db.cluster-x.us-east-1.rds.amazonaws.com" ;;
            "/vaultmtg/app/production/db-name")            echo "stubdb" ;;
            "/vaultmtg/app/production/latest-bff-sha")     echo "" ;;
            "/vaultmtg/app/production/domain-name")        echo "" ;;
            "/vaultmtg/app/production/certbot-email")      echo "stub@example.invalid" ;;
            *) echo "" ;;
        esac
        ;;
    *)
        # Any other aws sub-command is a silent no-op in dry-run.
        :
        ;;
esac
exit 0
AWSSTUB
    chmod +x "${d}/usr/local/bin/aws"

    # Stub provision-env.sh — writes KEY=VALUE to the legacy env path
    # (matches deploy-env.sh:63 BFF_ENV_FILE=/etc/mtga-companion/env).
    # The bootstrap section-2 symlink shim then makes both
    # /etc/mtga-companion/env and /etc/vaultmtg/env resolve to the same
    # file.
    cat > "${d}/tmp/provision-env.sh" <<'PROVENV'
#!/bin/bash
# Stub provision-env.sh — writes KEY=value to ${BOOTSTRAP_PREFIX}/etc/mtga-companion/env.
set -e
KEY="$1"
PARAM_NAME="$2"
# Lookup table — keyed off the SSM parameter name the real provisioner reads.
case "$PARAM_NAME" in
    "/vaultmtg/app/production/ALLOWED_ORIGINS")   VAL="https://app.vaultmtg.app" ;;
    "/vaultmtg/app/production/CLERK_SECRET_KEY")  VAL="sk_test_STUB_CLERK_SECRET" ;;
    "/vaultmtg/app/production/bff-admin-token")      VAL="STUB_BFF_ADMIN_TOKEN_VALUE" ;;
    "/vaultmtg/app/production/CLERK_FRONTEND_API")  VAL="https://clerk.vaultmtg.app" ;;
    *)                                               VAL="STUB_VALUE_FOR_${KEY}" ;;
esac
ENV_FILE="${BOOTSTRAP_PREFIX}/etc/mtga-companion/env"
# Upsert: drop existing line for KEY then append.
mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
sed -i.bak "/^${KEY}=/d" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
echo "${KEY}=${VAL}" >> "$ENV_FILE"
echo "provision-env: ${KEY} -> ${ENV_FILE}"
PROVENV
    chmod +x "${d}/tmp/provision-env.sh"

    # Stub provision-db-url.sh — writes DATABASE_URL with credentials
    # to the legacy env path.
    cat > "${d}/tmp/provision-db-url.sh" <<'PROVDBURL'
#!/bin/bash
# Stub provision-db-url.sh — writes a credential-laden DATABASE_URL to
# ${BOOTSTRAP_PREFIX}/etc/mtga-companion/env.
set -e
ENV_FILE="${BOOTSTRAP_PREFIX}/etc/mtga-companion/env"
mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
sed -i.bak '/^DATABASE_URL=/d' "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
echo "DATABASE_URL=postgresql://stubuser:stubpw@stub-db.cluster-x.us-east-1.rds.amazonaws.com:5432/stubdb?sslmode=require" >> "$ENV_FILE"
echo "provision-db-url: DATABASE_URL -> ${ENV_FILE}"
PROVDBURL
    chmod +x "${d}/tmp/provision-db-url.sh"

    # Stub deploy-env.sh — sourced by some provision scripts but we
    # don't actually source it; existence is enough.
    echo '#!/bin/bash' > "${d}/tmp/deploy-env.sh"
    chmod +x "${d}/tmp/deploy-env.sh"

    echo "$d"
}

run_bootstrap() {
    local fixture="$1"
    # Run the bootstrap in dry-run mode against the fixture. Capture
    # both stdout and stderr; the bootstrap's `exec > >(tee ...)` line
    # is dry-run-gated so output stays inline.
    BOOTSTRAP_PREFIX="$fixture" \
    PATH="${fixture}/usr/local/bin:${PATH}" \
        bash "$BOOTSTRAP" --dry-run 2>&1
}

# ---------------------------------------------------------------------
# ASSERTION 3 — section 2 migrates real-dir legacy path
# ---------------------------------------------------------------------
echo "===================================================================="
echo "ASSERTION 3 — section 2 migration (legacy real-dir -> ENV_DIR + symlink)"
echo "===================================================================="
F3="$(make_fixture sec2-migration)"
# Pre-seed: /etc/mtga-companion already exists as a REAL DIRECTORY
# containing CLERK_SECRET_KEY (the bug-2 scenario).
mkdir -p "${F3}/etc/mtga-companion"
cat > "${F3}/etc/mtga-companion/env" <<EOF
CLERK_SECRET_KEY=sk_test_LEGACY_FROM_DEPLOY
EOF
chmod 600 "${F3}/etc/mtga-companion/env"

OUT3="$(run_bootstrap "$F3" 2>&1)" || { echo "BOOTSTRAP EXIT NONZERO"; echo "$OUT3"; KEEP_TMPDIRS=1; exit 1; }

# Verify: legacy path is now a symlink pointing at ENV_DIR. This is the
# core Bug 2 fix — without this, deploy-side provision scripts (which
# write to deploy-env.sh's BFF_ENV_FILE=/etc/mtga-companion/env) would
# land in the legacy directory while the systemd unit reads /etc/vaultmtg/env.
if [ ! -L "${F3}/etc/mtga-companion" ]; then
    echo "FAIL: ${F3}/etc/mtga-companion is not a symlink (still a real directory)"
    ls -la "${F3}/etc/" || true
    KEEP_TMPDIRS=1; exit 1
fi
# Verify: pre-migration backup directory exists (the migrated-aside copy
# left as a forensic breadcrumb).
if ! ls -d "${F3}/etc/mtga-companion.pre-window-b."* >/dev/null 2>&1; then
    echo "FAIL: pre-migration backup .pre-window-b.* not found"
    ls -la "${F3}/etc/" || true
    KEEP_TMPDIRS=1; exit 1
fi
# Verify: both paths now resolve to the same inode (the canonical env
# file written by section 3b's overlay).
INODE_CANONICAL="$(stat -f '%i' "${F3}/etc/vaultmtg/env" 2>/dev/null || stat -c '%i' "${F3}/etc/vaultmtg/env")"
INODE_LEGACY="$(stat -f '%i' "${F3}/etc/mtga-companion/env" 2>/dev/null || stat -c '%i' "${F3}/etc/mtga-companion/env")"
if [ "$INODE_CANONICAL" != "$INODE_LEGACY" ]; then
    echo "FAIL: canonical and legacy env paths resolve to different inodes (canonical=$INODE_CANONICAL legacy=$INODE_LEGACY)"
    KEEP_TMPDIRS=1; exit 1
fi
# Verify: CLERK_SECRET_KEY is present in the canonical env file (written
# by section 3b's overlay, which the symlink ensured landed in canonical).
if ! grep -q "^CLERK_SECRET_KEY=" "${F3}/etc/vaultmtg/env"; then
    echo "FAIL: CLERK_SECRET_KEY missing from canonical /etc/vaultmtg/env after migration + overlay"
    echo "--- contents:"
    cat "${F3}/etc/vaultmtg/env" || true
    KEEP_TMPDIRS=1; exit 1
fi
echo "ASSERTION 3 PASS (legacy dir migrated, symlink installed, inodes match, CLERK present)"
echo ""

# ---------------------------------------------------------------------
# ASSERTION 4 — section 3b overlays CLERK_SECRET_KEY into env file
# ---------------------------------------------------------------------
echo "===================================================================="
echo "ASSERTION 4 — section 3b: env file contains CLERK_SECRET_KEY after overlay"
echo "===================================================================="
F4="$(make_fixture sec3b-overlay)"
# No pre-seeded legacy dir; bootstrap creates symlink first, then
# section 3b stubs write CLERK_SECRET_KEY via the legacy path which
# resolves through the symlink to ENV_DIR/env.
OUT4="$(run_bootstrap "$F4" 2>&1)" || { echo "BOOTSTRAP EXIT NONZERO"; echo "$OUT4"; KEEP_TMPDIRS=1; exit 1; }

if ! grep -q "^CLERK_SECRET_KEY=sk_test_STUB_CLERK_SECRET$" "${F4}/etc/vaultmtg/env"; then
    echo "FAIL: CLERK_SECRET_KEY missing from /etc/vaultmtg/env after section-3b overlay"
    echo "--- env file contents:"
    cat "${F4}/etc/vaultmtg/env" 2>/dev/null || echo "(no file)"
    KEEP_TMPDIRS=1; exit 1
fi
# Also verify provision-db-url DATABASE_URL upsert
if ! grep -q "^DATABASE_URL=postgresql://stubuser:" "${F4}/etc/vaultmtg/env"; then
    echo "FAIL: credential-laden DATABASE_URL missing from /etc/vaultmtg/env after section-3b overlay"
    cat "${F4}/etc/vaultmtg/env"
    KEEP_TMPDIRS=1; exit 1
fi
echo "ASSERTION 4 PASS"
echo ""

# ---------------------------------------------------------------------
# ASSERTION 5 — section 6 preserves existing 443 block
# ---------------------------------------------------------------------
echo "===================================================================="
echo "ASSERTION 5 — section 6: existing nginx config with 'listen 443 ssl' preserved"
echo "===================================================================="
F5="$(make_fixture sec6-preserve-443)"
# Pre-seed: existing nginx config has both port-80 and port-443 blocks
# (matches the certbot-expanded production state).
mkdir -p "${F5}/etc/nginx/conf.d"
cat > "${F5}/etc/nginx/conf.d/mtga-companion.conf" <<'EXISTINGCONF'
# managed by Certbot (preserved by bootstrap)
server {
    listen 80 default_server;
    server_name _;
    location / { return 301 https://$host$request_uri; }
}

server {
    server_name api.vaultmtg.app;
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/api.vaultmtg.app/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.vaultmtg.app/privkey.pem;
    location /api/v1/ { proxy_pass http://127.0.0.1:8080; }
}
EXISTINGCONF
PRE_SHA="$(shasum -a 256 "${F5}/etc/nginx/conf.d/mtga-companion.conf" | awk '{print $1}')"

OUT5="$(run_bootstrap "$F5" 2>&1)" || { echo "BOOTSTRAP EXIT NONZERO"; echo "$OUT5"; KEEP_TMPDIRS=1; exit 1; }

POST_SHA="$(shasum -a 256 "${F5}/etc/nginx/conf.d/mtga-companion.conf" | awk '{print $1}')"

if [ "$PRE_SHA" != "$POST_SHA" ]; then
    echo "FAIL: nginx config was overwritten (PRE_SHA=$PRE_SHA POST_SHA=$POST_SHA)"
    echo "--- post-run contents:"
    cat "${F5}/etc/nginx/conf.d/mtga-companion.conf"
    KEEP_TMPDIRS=1; exit 1
fi
if ! grep -q "listen 443 ssl" "${F5}/etc/nginx/conf.d/mtga-companion.conf"; then
    echo "FAIL: 'listen 443 ssl' missing after run"
    KEEP_TMPDIRS=1; exit 1
fi
echo "ASSERTION 5 PASS (file unchanged, sha=$POST_SHA)"
echo ""

# ---------------------------------------------------------------------
# ASSERTION 6 — section 6 writes fresh template into empty conf.d
# ---------------------------------------------------------------------
echo "===================================================================="
echo "ASSERTION 6 — section 6: empty nginx conf.d gets fresh port-80 template"
echo "===================================================================="
F6="$(make_fixture sec6-write-fresh)"
# No pre-seeded nginx config.

OUT6="$(run_bootstrap "$F6" 2>&1)" || { echo "BOOTSTRAP EXIT NONZERO"; echo "$OUT6"; KEEP_TMPDIRS=1; exit 1; }

if [ ! -f "${F6}/etc/nginx/conf.d/mtga-companion.conf" ]; then
    echo "FAIL: nginx config file was not created"
    KEEP_TMPDIRS=1; exit 1
fi
if ! grep -q "listen 80 default_server" "${F6}/etc/nginx/conf.d/mtga-companion.conf"; then
    echo "FAIL: port-80 server block missing from fresh-write config"
    cat "${F6}/etc/nginx/conf.d/mtga-companion.conf"
    KEEP_TMPDIRS=1; exit 1
fi
# Fresh write should NOT have 443 ssl yet (certbot will expand on first install)
if grep -q "listen 443 ssl" "${F6}/etc/nginx/conf.d/mtga-companion.conf"; then
    echo "FAIL: 'listen 443 ssl' present in fresh-write config (should not be — certbot has not run)"
    KEEP_TMPDIRS=1; exit 1
fi
echo "ASSERTION 6 PASS (fresh port-80 template written)"
echo ""

# ---------------------------------------------------------------------
# ASSERTION 7 — section 3b overlays BFF_ADMIN_TOKEN into env file
# (#2559: provision-env.sh BFF_ADMIN_TOKEN /vaultmtg/app/production/bff-admin-token)
# ---------------------------------------------------------------------
echo "===================================================================="
echo "ASSERTION 7 — section 3b: env file contains BFF_ADMIN_TOKEN after overlay"
echo "===================================================================="
F7="$(make_fixture sec3b-bff-admin-token)"
OUT7="$(run_bootstrap "$F7" 2>&1)" || { echo "BOOTSTRAP EXIT NONZERO"; echo "$OUT7"; KEEP_TMPDIRS=1; exit 1; }

if ! grep -q "^BFF_ADMIN_TOKEN=STUB_BFF_ADMIN_TOKEN_VALUE$" "${F7}/etc/vaultmtg/env"; then
    echo "FAIL: BFF_ADMIN_TOKEN missing from /etc/vaultmtg/env after section-3b overlay"
    echo "--- env file contents:"
    cat "${F7}/etc/vaultmtg/env" 2>/dev/null || echo "(no file)"
    KEEP_TMPDIRS=1; exit 1
fi
echo "ASSERTION 7 PASS (BFF_ADMIN_TOKEN present in canonical env file)"
echo ""

# ---------------------------------------------------------------------
# ASSERTION 8 — section 3b overlays CLERK_FRONTEND_API into env file
# (#276: provision-env.sh CLERK_FRONTEND_API /vaultmtg/app/production/CLERK_FRONTEND_API)
# No --with-decryption: plain String param.
# ---------------------------------------------------------------------
echo "===================================================================="
echo "ASSERTION 8 — section 3b: env file contains CLERK_FRONTEND_API after overlay"
echo "===================================================================="
F8="$(make_fixture sec3b-clerk-frontend-api)"
OUT8="$(run_bootstrap "$F8" 2>&1)" || { echo "BOOTSTRAP EXIT NONZERO"; echo "$OUT8"; KEEP_TMPDIRS=1; exit 1; }

if ! grep -q "^CLERK_FRONTEND_API=https://clerk.vaultmtg.app$" "${F8}/etc/vaultmtg/env"; then
    echo "FAIL: CLERK_FRONTEND_API missing from /etc/vaultmtg/env after section-3b overlay"
    echo "--- env file contents:"
    cat "${F8}/etc/vaultmtg/env" 2>/dev/null || echo "(no file)"
    KEEP_TMPDIRS=1; exit 1
fi
echo "ASSERTION 8 PASS (CLERK_FRONTEND_API present in canonical env file)"
echo ""

echo "===================================================================="
echo "ALL SELFTEST ASSERTIONS PASS"
echo "===================================================================="
