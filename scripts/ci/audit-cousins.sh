#!/usr/bin/env bash
# audit-cousins.sh -- Missed-cousin auditor for mtga-companion-infra
#
# PURPOSE
# -------
# Detects "missed cousin" gaps: when a new resource is added to a CFN template
# (new RDS instance, new SG, new GHA environment), other IAM/policy/SG configs
# that likely need to reference the new resource are checked and flagged.
#
# OUTPUT
# ------
# Prints a warning block for each detected gap.  Exits 0 regardless of whether
# gaps were found -- this is a warn-only tool, not a hard-fail gate.  The caller
# (missed-cousin-auditor.yml) posts the output as a PR comment when gaps exist.
#
# USAGE
# -----
#   # Run against a specific changed template (local testing)
#   bash scripts/ci/audit-cousins.sh cloudformation/rds-vaultmtg-staging.yml
#
#   # Run against all CFN templates changed in the current PR (CI mode)
#   bash scripts/ci/audit-cousins.sh  # reads CHANGED_TEMPLATES env var
#
# DESIGN
# ------
# See vault-mtg-docs/engineering/runbooks/missed-cousin-auditor.md for the full
# design rationale, cousin-class definitions, and backtest results.
# Ticket: vault-mtg-tickets#52

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the list of changed templates
# ---------------------------------------------------------------------------
TEMPLATES=""
if [ $# -gt 0 ]; then
  TEMPLATES="$*"
elif [ -n "${CHANGED_TEMPLATES:-}" ]; then
  TEMPLATES="$CHANGED_TEMPLATES"
else
  echo "[audit-cousins] No templates specified and CHANGED_TEMPLATES not set. Nothing to audit."
  exit 0
fi

# Repo root: the directory this script lives in, two levels up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

IAM_ROLES_FILE="${REPO_ROOT}/cloudformation/iam-gha-roles.yml"
STAGING_DEPLOY_ROLE_FILE="${REPO_ROOT}/cloudformation/staging-deploy-role.yml"
DEPLOY_YML_FILE="${REPO_ROOT}/.github/workflows/deploy.yml"

# The diff to analyze (used by Class D)
# In CI, GITHUB_BASE_REF is set; locally, compare against origin/main.
# DIFF_BASE_OVERRIDE allows local backtest runs to specify an exact ref
# (e.g. a commit hash or local tag) without needing a remote.
if [ -n "${DIFF_BASE_OVERRIDE:-}" ]; then
  DIFF_BASE="${DIFF_BASE_OVERRIDE}"
elif [ -n "${GITHUB_BASE_REF:-}" ]; then
  DIFF_BASE="origin/${GITHUB_BASE_REF}"
else
  DIFF_BASE="origin/main"
fi

GAPS_FOUND=0
OUTPUT_LINES=()

# ---------------------------------------------------------------------------
# Helper: emit a gap warning
# ---------------------------------------------------------------------------
gap() {
  local CLASS="$1"
  local TRIGGER_FILE="$2"
  local GAP_FILE="$3"
  local MESSAGE="$4"
  local SUGGESTION="$5"

  GAPS_FOUND=$((GAPS_FOUND + 1))
  OUTPUT_LINES+=("")
  OUTPUT_LINES+=("### Gap #${GAPS_FOUND} -- Class ${CLASS}")
  OUTPUT_LINES+=("**Trigger:** \`${TRIGGER_FILE}\`")
  OUTPUT_LINES+=("**Suspected gap in:** \`${GAP_FILE}\`")
  OUTPUT_LINES+=("**Issue:** ${MESSAGE}")
  OUTPUT_LINES+=("**Suggested fix:** ${SUGGESTION}")
}

# ---------------------------------------------------------------------------
# Class B: New AWS::RDS::DBInstance with ManageMasterUserPassword: true
#
# When a new RDS instance is added with managed secrets, staging-deploy-role.yml
# needs a GetSecretValue grant for the new secret (rds!db-<id>-*).
# The exact ARN is unknown at PR time; flag the gap so the engineer adds it
# post-first-deploy once the real resource ID is known.
# ---------------------------------------------------------------------------
check_class_b() {
  local TEMPLATE_FILE="$1"

  # Does this template add a new DBInstance with ManageMasterUserPassword?
  # Check the file itself (not just the diff) since we want to catch net-new files.
  if ! grep -q "Type: AWS::RDS::DBInstance" "${REPO_ROOT}/${TEMPLATE_FILE}" 2>/dev/null; then
    return 0
  fi

  if ! grep -q "ManageMasterUserPassword: true" "${REPO_ROOT}/${TEMPLATE_FILE}" 2>/dev/null; then
    return 0
  fi

  # Is this a NEW template (not previously on main)?
  IS_NEW_FILE=false
  if ! git -C "${REPO_ROOT}" show "${DIFF_BASE}:${TEMPLATE_FILE}" >/dev/null 2>&1; then
    IS_NEW_FILE=true
  fi

  # If not a new file, check whether this specific resource was just added in the diff.
  if [ "$IS_NEW_FILE" = "false" ]; then
    NEW_RDS=$(git -C "${REPO_ROOT}" diff "${DIFF_BASE}...HEAD" -- "${TEMPLATE_FILE}" 2>/dev/null \
      | grep "^+" | grep -c "Type: AWS::RDS::DBInstance" || true)
    if [ "${NEW_RDS}" -eq 0 ]; then
      return 0
    fi
  fi

  # Is there a NEW rds!db- entry in staging-deploy-role.yml in this PR diff?
  NEW_SECRET_GRANT=$(git -C "${REPO_ROOT}" diff "${DIFF_BASE}...HEAD" -- "${STAGING_DEPLOY_ROLE_FILE}" 2>/dev/null \
    | grep "^+" | grep -c "rds!db-" || true)

  if [ "${NEW_SECRET_GRANT}" -eq 0 ]; then
    gap "B (New RDS managed secret)" \
      "${TEMPLATE_FILE}" \
      "cloudformation/staging-deploy-role.yml" \
      "A new AWS::RDS::DBInstance with ManageMasterUserPassword: true was added but staging-deploy-role.yml does not have a new rds!db-* GetSecretValue grant in this PR." \
      "After first deploy, find the new RDS instance's resource ID (AWS console or 'aws rds describe-db-instances') and add 'arn:aws:secretsmanager:\${AWS::Region}:\${AWS::AccountId}:secret:rds!db-<id>-*' to the StagingDBSecretRead policy in staging-deploy-role.yml."
  fi
}

# ---------------------------------------------------------------------------
# Class C: New EC2 security group / changed SG parameter
#
# When a parameters file changes a *SecurityGroupId value, check whether
# other parameter files or templates still reference the OLD SG ID.
# Also flags when a new AWS::EC2::SecurityGroup is added but no corresponding
# parameter file is updated to point at it.
# ---------------------------------------------------------------------------
check_class_c() {
  local TEMPLATE_FILE="$1"
  local PARAMS_FILE
  PARAMS_FILE="${REPO_ROOT}/cloudformation/parameters/$(basename "$TEMPLATE_FILE" .yml).json"

  # Case 1: parameters file changed -- check for stale old SG IDs elsewhere
  PARAMS_BASENAME="cloudformation/parameters/$(basename "$TEMPLATE_FILE" .yml).json"
  if git -C "${REPO_ROOT}" diff "${DIFF_BASE}...HEAD" -- "${PARAMS_BASENAME}" 2>/dev/null | grep -q "sg-"; then
    # Extract removed SG IDs (the old values)
    OLD_SGS=$(git -C "${REPO_ROOT}" diff "${DIFF_BASE}...HEAD" -- "${PARAMS_BASENAME}" 2>/dev/null \
      | grep "^-" | grep -oE "sg-[0-9a-f]{17}" || true)

    for OLD_SG in $OLD_SGS; do
      # Check whether any OTHER parameter file still references this SG
      STALE_REFS=$(grep -rl "${OLD_SG}" "${REPO_ROOT}/cloudformation/parameters/" 2>/dev/null \
        | grep -v "$(basename "$PARAMS_FILE")" || true)

      if [ -n "${STALE_REFS}" ]; then
        for STALE_FILE in ${STALE_REFS}; do
          STALE_REL="${STALE_FILE#"${REPO_ROOT}"/}"
          gap "C (Stale SG reference)" \
            "${PARAMS_BASENAME}" \
            "${STALE_REL}" \
            "SG ID ${OLD_SG} was replaced in ${PARAMS_BASENAME} but ${STALE_REL} still references it." \
            "Update the SG ID in '${STALE_REL}' to the new value, or verify it intentionally uses a different SG."
        done
      fi
    done

    # Also check template files for hardcoded references to the old SG
    for OLD_SG in $OLD_SGS; do
      STALE_TEMPLATE_REFS=$(grep -rl "${OLD_SG}" "${REPO_ROOT}/cloudformation/" 2>/dev/null \
        | grep -v "parameters/" || true)

      for STALE_FILE in ${STALE_TEMPLATE_REFS}; do
        STALE_REL="${STALE_FILE#"${REPO_ROOT}"/}"
        # Skip if the stale reference is in the template that was itself changed
        if [ "${STALE_REL}" = "${TEMPLATE_FILE}" ]; then
          continue
        fi
        gap "C (Hardcoded stale SG in template)" \
          "${PARAMS_BASENAME}" \
          "${STALE_REL}" \
          "SG ID ${OLD_SG} was replaced in ${PARAMS_BASENAME} but a hardcoded reference to it still exists in ${STALE_REL}." \
          "Replace the hardcoded SG ID ${OLD_SG} in '${STALE_REL}' with the correct SG ID."
      done
    done
  fi

  # Case 2: new AWS::EC2::SecurityGroup added -- check that the SG parameter is NOT a phantom
  if ! grep -q "Type: AWS::EC2::SecurityGroup" "${REPO_ROOT}/${TEMPLATE_FILE}" 2>/dev/null; then
    return 0
  fi

  IS_NEW_FILE=false
  if ! git -C "${REPO_ROOT}" show "${DIFF_BASE}:${TEMPLATE_FILE}" >/dev/null 2>&1; then
    IS_NEW_FILE=true
  fi

  if [ "$IS_NEW_FILE" = "false" ]; then
    NEW_SG=$(git -C "${REPO_ROOT}" diff "${DIFF_BASE}...HEAD" -- "${TEMPLATE_FILE}" 2>/dev/null \
      | grep "^+" | grep -c "Type: AWS::EC2::SecurityGroup" || true)
    if [ "${NEW_SG}" -eq 0 ]; then
      return 0
    fi
  fi

  # Is there a corresponding parameters file for this template?
  if [ -f "${PARAMS_FILE}" ]; then
    # Does the params file contain a SecurityGroupId that looks like a non-existent SG?
    # We can't verify existence at PR time, but we can flag if the params file hasn't
    # been updated in this PR while the template was.
    PARAMS_UPDATED=$(git -C "${REPO_ROOT}" diff "${DIFF_BASE}...HEAD" -- "${PARAMS_BASENAME}" 2>/dev/null | wc -l || echo "0")

    if [ "${PARAMS_UPDATED}" -eq 0 ]; then
      gap "C (New SG, parameters not updated)" \
        "${TEMPLATE_FILE}" \
        "${PARAMS_BASENAME}" \
        "A new AWS::EC2::SecurityGroup was added to ${TEMPLATE_FILE} but the parameters file ${PARAMS_BASENAME} was not updated in this PR." \
        "Verify that '${PARAMS_BASENAME}' has the correct EC2SecurityGroupId and SyncLambdaSecurityGroupId values for the new stack. Use the real SG IDs from 'aws ec2 describe-security-groups'."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Class D (sub-case D2 only): IAM template changed -- new environment sub
# added to ONE role; check if other roles in iam-gha-roles.yml are missing it.
#
# Sub-case D1 (deploy.yml changed -> check IAM trust policies) is handled by
# check_class_d1_global() below, called ONCE after the main template loop so
# it never fires multiple times from different template iterations.
# ---------------------------------------------------------------------------
check_class_d2() {
  local TEMPLATE_FILE="$1"

  if [ "${TEMPLATE_FILE}" = "cloudformation/iam-gha-roles.yml" ] || \
     [ "${TEMPLATE_FILE}" = "cloudformation/staging-deploy-role.yml" ]; then

    local TEMPLATE_DIFF
    TEMPLATE_DIFF=$(git -C "${REPO_ROOT}" diff "${DIFF_BASE}...HEAD" -- "${TEMPLATE_FILE}" 2>/dev/null || true)
    local NEW_ENV_SUBS
    NEW_ENV_SUBS=$(echo "${TEMPLATE_DIFF}" | grep "^+" | grep -oE "environment:[a-zA-Z0-9_-]+" | sort -u || true)

    for ENV_SUB in $NEW_ENV_SUBS; do
      local ENV_NAME="${ENV_SUB#environment:}"
      if [ "${ENV_NAME}" = "production" ] || [ "${ENV_NAME}" = "staging-alerts" ]; then
        continue
      fi

      if [ -f "${IAM_ROLES_FILE}" ]; then
        local TOTAL_ROLE_BLOCKS
        TOTAL_ROLE_BLOCKS=$(grep -c "Type: AWS::IAM::Role" "${IAM_ROLES_FILE}" 2>/dev/null || true)
        local ENV_OCCURRENCES
        # Count infra-repo sub-claim value lines only (exclude comments and non-infra repo entries).
        # Anchor: require the env name to NOT be followed by '-' (prevents staging matching staging-alerts).
        ENV_OCCURRENCES=$(grep "environment:${ENV_NAME}" "${IAM_ROLES_FILE}" 2>/dev/null \
          | grep -v "^[[:space:]]*#" \
          | grep -E "(InfraRepo|mtga-companion-infra|vault-mtg-infra):environment:${ENV_NAME}" \
          | grep -cv ":environment:${ENV_NAME}-" \
          || true)

        # Heuristic: each role that runs in this environment needs at least TWO entries
        # (parameterized + legacy literal per #1759 PR-B dual-trust pattern).
        # If fewer than 2*number_of_roles_using_env occurrences exist, some roles are likely missing.
        # We use a simpler check: < 2 occurrences means at most one role has the entry.
        if [ "${TOTAL_ROLE_BLOCKS}" -gt 1 ] && [ "${ENV_OCCURRENCES}" -lt 2 ]; then
          local IAM_ROLES_REL="${IAM_ROLES_FILE#"${REPO_ROOT}"/}"
          gap "D (New env sub in one role, other roles may be missing it)" \
            "${TEMPLATE_FILE}" \
            "${IAM_ROLES_REL}" \
            "A new 'environment:${ENV_NAME}' sub-claim was added to ${TEMPLATE_FILE} but ${IAM_ROLES_REL} has only ${ENV_OCCURRENCES} infra-repo occurrence(s) of 'environment:${ENV_NAME}'. There are ${TOTAL_ROLE_BLOCKS} IAM roles -- verify all roles that run jobs in environment '${ENV_NAME}' have the sub-claim." \
            "Check each GhaInfra*Role in cloudformation/iam-gha-roles.yml. Add 'environment:${ENV_NAME}' sub entries (both parameterized + legacy literal per the #1759 PR-B pattern) to every role whose deploy jobs run in environment '${ENV_NAME}'."
        fi
      fi
    done
  fi
}

# ---------------------------------------------------------------------------
# Class D (sub-case D1): deploy.yml changed -- detect new GHA environment
# names and verify IAM trust policies include those environments.
#
# Called ONCE after the main template loop (not per-template) to avoid
# duplicate gap reports when both deploy.yml and a CFN template are changed.
# ---------------------------------------------------------------------------
check_class_d1_global() {
  local DEPLOY_DIFF
  DEPLOY_DIFF=$(git -C "${REPO_ROOT}" diff "${DIFF_BASE}...HEAD" -- "${DEPLOY_YML_FILE}" 2>/dev/null || true)
  if [ -z "${DEPLOY_DIFF}" ]; then
    return 0
  fi

  # Extract newly added environment names from deploy.yml diff.
  # Two patterns must be handled:
  #   1. Simple literal:  environment: staging
  #   2. GHA ternary:     environment: ${{ ... && 'staging' || 'production' }}
  # For pattern 2, extract single-quoted string values from any added line
  # that also contains the word "environment".
  local LITERAL_ENVS
  LITERAL_ENVS=$(echo "${DEPLOY_DIFF}" | grep "^+" | grep "environment:" \
    | grep -oE "environment:[[:space:]]*['\"]?[a-zA-Z0-9_-]+" \
    | sed "s/environment:[[:space:]]*//" | sed "s/['\"]//g" || true)
  local TERNARY_ENVS
  TERNARY_ENVS=$(echo "${DEPLOY_DIFF}" | grep "^+" | grep "environment" \
    | grep -oE "'[a-zA-Z0-9_-]+'" | sed "s/'//g" || true)
  local NEW_ENVS
  NEW_ENVS=$(printf '%s\n%s\n' "$LITERAL_ENVS" "$TERNARY_ENVS" | sort -u | grep -v "^$" || true)

  for ENV_NAME in $NEW_ENVS; do
    # Skip always-present environments
    if [ "${ENV_NAME}" = "production" ] || [ "${ENV_NAME}" = "staging-alerts" ]; then
      continue
    fi

    # Check iam-gha-roles.yml for infra-repo sub-claims.
    # Note: staging-deploy-role.yml uses the APP repo sub-claim (${GitHubRepo} = vault-mtg),
    # not the infra repo sub-claim. It is NOT checked here; its trust policy is self-contained.
    local ROLE_FILE="${IAM_ROLES_FILE}"
    local ROLE_REL="${ROLE_FILE#"${REPO_ROOT}"/}"
    if [ ! -f "${ROLE_FILE}" ]; then
      return 0
    fi

    # Count infra-repo sub-claim value lines only.
    # Anchored: env name must NOT be followed by '-' to prevent false matches (staging -> staging-alerts).
    local ENV_IN_ROLE
    ENV_IN_ROLE=$(grep "environment:${ENV_NAME}" "${ROLE_FILE}" 2>/dev/null \
      | grep -v "^[[:space:]]*#" \
      | grep -E "(InfraRepo|mtga-companion-infra|vault-mtg-infra):environment:${ENV_NAME}" \
      | grep -cv ":environment:${ENV_NAME}-" \
      || true)
    if [ "${ENV_IN_ROLE}" -eq 0 ]; then
      gap "D (New GHA environment, IAM trust not updated)" \
        ".github/workflows/deploy.yml" \
        "${ROLE_REL}" \
        "deploy.yml added or references GHA environment '${ENV_NAME}' but ${ROLE_REL} does not contain an infra-repo 'environment:${ENV_NAME}' sub-claim in any GhaInfra*Role trust policy. Infra deploy jobs in this environment will get AssumeRoleWithWebIdentity denials." \
        "Add both the parameterized form ('!Sub repo:\${GitHubOrg}/\${InfraRepo}:environment:${ENV_NAME}') and the legacy literal form ('repo:RdHamilton/mtga-companion-infra:environment:${ENV_NAME}') to every GhaInfra*Role trust policy that runs jobs in environment '${ENV_NAME}'. See PR #239 and #243 for the pattern."
    fi
  done
}

# ---------------------------------------------------------------------------
# Main loop: iterate over changed templates and run each cousin class
# ---------------------------------------------------------------------------
echo "[audit-cousins] Scanning changed templates..."
echo ""

for TEMPLATE_FILE in $TEMPLATES; do
  # Normalize: strip leading ./ if present
  TEMPLATE_FILE="${TEMPLATE_FILE#./}"

  echo "[audit-cousins] Checking: ${TEMPLATE_FILE}"

  case "${TEMPLATE_FILE}" in
    cloudformation/*.yml)
      check_class_b "${TEMPLATE_FILE}"
      check_class_c "${TEMPLATE_FILE}"
      check_class_d2 "${TEMPLATE_FILE}"
      ;;
    .github/workflows/deploy.yml)
      # deploy.yml: no per-template class checks; D1 runs globally below
      ;;
    *)
      # Not a CFN template or deploy.yml -- skip
      ;;
  esac
done

# Class D1: run once globally after the template loop (avoids duplicate reports
# when both deploy.yml and a CFN template are in the same PR diff).
check_class_d1_global

echo ""
echo "[audit-cousins] Scan complete. Gaps found: ${GAPS_FOUND}"

# ---------------------------------------------------------------------------
# Print final output
# ---------------------------------------------------------------------------
if [ "${GAPS_FOUND}" -gt 0 ]; then
  echo ""
  echo "## Missed-Cousin Auditor: ${GAPS_FOUND} potential gap(s) detected"
  echo ""
  echo "> **Warning (not a hard-fail):** These are heuristic findings. Engineers may"
  echo "> have intentional reasons not to update a cousin resource in this PR. Review"
  echo "> each gap and confirm or dismiss as appropriate before merge."
  echo ""
  for LINE in "${OUTPUT_LINES[@]}"; do
    echo "${LINE}"
  done
  echo ""
  echo "---"
  echo "Runbook: vault-mtg-docs/engineering/runbooks/missed-cousin-auditor.md"
  echo "Ticket: vault-mtg-tickets#52"
fi

# Always exit 0 -- this is a warn-only tool
exit 0
