#!/usr/bin/env bash
# strip-default-sg.sh -- Revoke all inbound and outbound rules on the default
# VPC security group (S-21 / #2358).
#
# WHY THIS IS A SCRIPT, NOT CLOUDFORMATION
# ----------------------------------------
# CloudFormation cannot manage the default VPC security group declaratively.
# The default SG is owned by EC2 / VPC, not by any stack:
#
#   * AWS::EC2::SecurityGroup creates a NEW security group; it cannot adopt
#     the existing "default" SG. Its GroupName must be unique within the VPC
#     and cannot be "default".
#   * AWS::EC2::SecurityGroupIngress / SecurityGroupEgress only ADD rules
#     to an existing GroupId. They cannot represent the ABSENCE of rules.
#   * No managed remediation in CloudFormation revokes the AWS-created
#     defaults (self-reference inbound + 0.0.0.0/0 all-protocols outbound).
#
# The CIS Benchmark (4.3) and AWS Config managed rule
# (vpc-default-security-group-closed) both require these defaults removed.
# This script is the canonical idempotent remediation, runnable from CI/CD.
#
# IDEMPOTENCY
# -----------
# Revoking a rule that does not exist returns an "InvalidPermission.NotFound"
# error. We trap that case and treat it as success, so re-runs are no-ops.
#
# USAGE
# -----
#   AWS_PROFILE=personal ./scripts/security/strip-default-sg.sh [VPC_ID]
#
# VPC_ID defaults to the VaultMTG default VPC (vpc-01d097c495e941d32).
#
# VERIFICATION
# ------------
# After running, the default SG must show empty IpPermissions AND
# IpPermissionsEgress arrays:
#
#   aws ec2 describe-security-groups \
#     --filters Name=group-name,Values=default \
#               Name=vpc-id,Values=vpc-01d097c495e941d32 \
#     --query 'SecurityGroups[0].[IpPermissions,IpPermissionsEgress]' \
#     --profile personal --region us-east-1

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${1:-vpc-01d097c495e941d32}"
PROFILE_ARG=""
if [ -n "${AWS_PROFILE:-}" ]; then
    PROFILE_ARG="--profile ${AWS_PROFILE}"
fi

log() { echo "[strip-default-sg] $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

log "Resolving default SG for VPC ${VPC_ID}..."
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=default" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region "${REGION}" \
    ${PROFILE_ARG})

if [ -z "${SG_ID}" ] || [ "${SG_ID}" = "None" ]; then
    log "FATAL: could not find default SG for VPC ${VPC_ID}"
    exit 1
fi
log "Default SG: ${SG_ID}"

# Snapshot existing rules so we can revoke them by JSON descriptor.
INGRESS_JSON=$(aws ec2 describe-security-groups \
    --group-ids "${SG_ID}" \
    --query 'SecurityGroups[0].IpPermissions' \
    --output json \
    --region "${REGION}" \
    ${PROFILE_ARG})
EGRESS_JSON=$(aws ec2 describe-security-groups \
    --group-ids "${SG_ID}" \
    --query 'SecurityGroups[0].IpPermissionsEgress' \
    --output json \
    --region "${REGION}" \
    ${PROFILE_ARG})

revoke_idempotent() {
    local direction="$1" # ingress|egress
    local rules_json="$2"
    local count
    count=$(echo "${rules_json}" | jq 'length')
    if [ "${count}" -eq 0 ]; then
        log "No ${direction} rules present -- nothing to revoke."
        return 0
    fi
    log "Revoking ${count} ${direction} rule(s)..."
    if [ "${direction}" = "ingress" ]; then
        aws ec2 revoke-security-group-ingress \
            --group-id "${SG_ID}" \
            --ip-permissions "${rules_json}" \
            --region "${REGION}" \
            ${PROFILE_ARG} 2>&1 | tee /tmp/strip-default-sg-${direction}.log || {
                if grep -q "InvalidPermission.NotFound" /tmp/strip-default-sg-${direction}.log; then
                    log "Rules already absent (idempotent re-run) -- treating as success."
                    return 0
                fi
                log "FATAL: revoke-${direction} failed"
                return 1
            }
    else
        aws ec2 revoke-security-group-egress \
            --group-id "${SG_ID}" \
            --ip-permissions "${rules_json}" \
            --region "${REGION}" \
            ${PROFILE_ARG} 2>&1 | tee /tmp/strip-default-sg-${direction}.log || {
                if grep -q "InvalidPermission.NotFound" /tmp/strip-default-sg-${direction}.log; then
                    log "Rules already absent (idempotent re-run) -- treating as success."
                    return 0
                fi
                log "FATAL: revoke-${direction} failed"
                return 1
            }
    fi
}

revoke_idempotent ingress "${INGRESS_JSON}"
revoke_idempotent egress  "${EGRESS_JSON}"

log "Verifying final state..."
FINAL=$(aws ec2 describe-security-groups \
    --group-ids "${SG_ID}" \
    --query 'SecurityGroups[0].[IpPermissions,IpPermissionsEgress]' \
    --output json \
    --region "${REGION}" \
    ${PROFILE_ARG})
INGRESS_COUNT=$(echo "${FINAL}" | jq '.[0] | length')
EGRESS_COUNT=$(echo "${FINAL}" | jq '.[1] | length')
log "Final state: inbound=${INGRESS_COUNT} rules, outbound=${EGRESS_COUNT} rules"

if [ "${INGRESS_COUNT}" -ne 0 ] || [ "${EGRESS_COUNT}" -ne 0 ]; then
    log "FATAL: default SG ${SG_ID} still has rules after revocation."
    exit 1
fi

log "Default SG ${SG_ID} is now closed (zero ingress, zero egress)."
