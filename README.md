# mtga-companion-infra

Infrastructure as Code for MTGA Companion — CloudFormation templates, EC2/RDS setup, nginx config, and deployment scripts.

## Structure

```
cloudformation/   — AWS CloudFormation templates (VPC, RDS, EC2)
scripts/          — Bootstrap and deploy scripts
nginx/            — nginx site configuration
systemd/          — systemd service definitions
```

## AWS Account

Account: 901347789205 — always use `AWS_PROFILE=personal`

## Manual Deployment (GitHub Actions)

Deployments are triggered manually via **Actions → Deploy CloudFormation Stack → Run workflow**.

Select a stack and optionally enable **dry run** to preview the changeset without applying it.

### Required GitHub Secrets

Set these in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user access key (deploy permissions) |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |

### Required IAM permissions for the deploy user

```
cloudformation:*
rds:*
ec2:*  (security groups, subnets)
iam:PassRole
```

### Before deploying RDS

Fill in the real resource IDs in `cloudformation/parameters/rds.json`:
- `VpcId`, `PrivateSubnet1Id`, `PrivateSubnet2Id` — from the VPC stack outputs
- `EC2SecurityGroupId` — from the EC2 stack outputs
- DB password is managed by AWS Secrets Manager (`ManageMasterUserPassword: true`) — no secret needed

## Deployment Order

Run stacks in this order — each depends on the previous:

1. `ec2-sg.yml` — EC2 security group
2. `rds.yml` — RDS PostgreSQL db.t3.micro (imports EC2 SG; exports DBSecretArn)
3. `ec2.yml` — EC2 t3.small + IAM instance profile (imports DBSecretArn)

Route 53 records for `vaultmtg.app` are managed directly in the AWS console — not via CloudFormation. The `rhamiltoneng-dns.yml` stack is the only DNS template in this repo and covers only the `rhamiltoneng.com` zone.

**Hold all deployments until AWS Activate credits are confirmed.**

## Status

- [ ] VPC + security groups (`cloudformation/vpc.yml`)
- [x] RDS PostgreSQL db.t3.micro (`cloudformation/rds.yml`) — pgvector-enabled, private subnet only
- [x] EC2 IAM instance profile + Secrets Manager access (`cloudformation/ec2.yml`) — ready to deploy
- [ ] nginx + SSL (`nginx/mtga-companion.conf`)
- [ ] systemd service (`systemd/mtga-companion.service`)
- [ ] GitHub Actions deploy step

## Frontend Serving

Production frontend is served by **Vercel** -- see ADR-007 in the main app repo (RdHamilton/MTGA-Companion).

The EC2 nginx static-serve path (`/var/www/mtga-companion/`) is preserved for disaster recovery and preview only. There is intentionally no automatic frontend deploy workflow in this repo. The EC2 frontend deploy workflow lives in the app repo (`.github/workflows/frontend.yml`) and is `workflow_dispatch`-only.

A duplicate `deploy-frontend.yml` that existed in this repo was removed in PR #18 (closes RdHamilton/MTGA-Companion#1211).
