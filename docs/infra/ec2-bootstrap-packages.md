# EC2 Bootstrap Packages

## Overview

The staging/production EC2 instance runs **Amazon Linux 2023** (AL2023) and is bootstrapped via CloudFormation UserData. All system packages are installed via `dnf`.

## Required Packages

The following packages are installed during bootstrap (see `cloudformation/ec2.yml` → UserData section 1, and `scripts/setup.sh` → "System packages"):

| Package | Purpose |
|---|---|
| `nginx` | Reverse proxy for the BFF service |
| `logrotate` | Log rotation for application logs |
| `aws-cli` | AWS SDK — SSM, S3, Secrets Manager access |
| `jq` | JSON parsing in shell scripts |
| `python3`, `python3-pip` | Runtime for certbot |
| `postgresql15` | PostgreSQL 15 client — provides `psql` for migration ownership transfer (required by `run-staging-migrations.sh`) |

## Why `postgresql15` is Required

The staging deploy pipeline (`staging-deploy.yml`, step "Run database migrations via SSM") runs `infra/scripts/run-staging-migrations.sh` on the EC2 instance via SSM RunCommand. That script uses `psql` to reassign table ownership to the `vaultmtg_app` role before invoking `golang-migrate`.

Without `postgresql15` installed, this step fails with:

```
/tmp/run-staging-migrations.sh: line 166: psql: command not found
failed to run commands: exit status 127
```

**Issue:** `postgresql15` must be installed via `dnf` (not `apt-get`) — this instance is Amazon Linux 2023, not Ubuntu/Debian.

## Package Name by OS

| OS | Package Manager | Package Name |
|---|---|---|
| Amazon Linux 2023 | `dnf` | `postgresql15` |
| Amazon Linux 2 | `yum` | `postgresql` |
| Ubuntu / Debian | `apt` | `postgresql-client` |

## Incident History

- **2026-05-21** — `postgresql15` was missing from AL2023 bootstrap. Staging Deploy was blocked at step 12 ("Run database migrations via SSM") after PR #2421 (CLERK SSM params) resolved all earlier blockers. Root cause: the initial package list omitted the psql client. Fixed in mtga-companion-infra PR #63 (closes vault-mtg#2422).

## Adding a New Bootstrap Package

1. Determine the correct AL2023 package name: `dnf search <keyword>`
2. Add it to the `dnf install -y ...` line in both:
   - `cloudformation/ec2.yml` (UserData section "1. System packages")
   - `scripts/setup.sh` (section "1. System packages")
3. Run the ad-hoc SSM install on the live instance to unblock the current instance (it will not be re-bootstrapped until an EC2 replacement):
   ```bash
   aws ssm send-command \
     --profile personal \
     --region us-east-1 \
     --instance-ids <instance-id> \
     --document-name AWS-RunShellScript \
     --parameters 'commands=["dnf install -y <package>"]'
   ```
4. Open a PR — the fix bakes into the next instance launch via CloudFormation UserData.
