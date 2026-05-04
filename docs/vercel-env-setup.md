# Vercel Environment Variable Setup

## Overview

The MTGA Companion frontend is deployed to Vercel. It reads `VITE_BFF_URL` at build
time to know where the BFF (Go REST API on EC2) lives. This variable must be set in
the Vercel project for Production and Preview environments so cross-origin API calls
work correctly.

See ADR-006 (`docs/adr/ADR-006-vercel-bff-connectivity.md` in the app repo) for the
full connectivity design.

## Automated Setup (Recommended)

The `Set Vercel Environment Variables` workflow in this repo automates the process.

### Prerequisites

Add the following secrets to the infra repo
(**Settings -> Secrets and variables -> Actions**):

| Secret | How to obtain |
|---|---|
| `VERCEL_TOKEN` | Vercel dashboard -> Account Settings -> Tokens -> Create Token (scope: Full Account) |
| `VERCEL_ORG_ID` | `vercel whoami` or Vercel dashboard -> Settings -> General -> Team ID |
| `VERCEL_PROJECT_ID` | Vercel project -> Settings -> General -> Project ID |

These secrets are not sensitive in the same way as database passwords -- they grant
Vercel API access -- but they must still be stored only in GitHub Secrets, never in
files or workflow YAML.

### Running the workflow

1. Go to **Actions -> Set Vercel Environment Variables -> Run workflow**.
2. Leave `bff_url_override` empty to auto-detect the EC2 public IP, or paste an
   explicit URL (e.g. `https://api.mtga-companion.com/api/v1` once a domain is live).
3. Run with `dry_run=true` first to confirm the resolved URL.
4. Run with `dry_run=false` to apply.

The workflow sets `VITE_BFF_URL` for both `production` and `preview` Vercel
environments and prints a verification list at the end.

### Updating after a domain is purchased

Once DNS is active (#977), run the workflow again with:

```
bff_url_override = https://api.mtga-companion.com/api/v1
```

This overwrites the IP-based value with the stable domain URL.

## Manual Setup (Fallback)

If the workflow cannot run (e.g. Vercel CLI version incompatibility):

1. Determine the BFF URL:
   - With domain: `https://api.mtga-companion.com/api/v1`
   - Without domain (current): `http://<EC2-public-IP>/api/v1`
   - Get EC2 IP: `aws ec2 describe-instances --instance-ids i-02477e36503aef863 --region us-east-1 --profile personal --query 'Reservations[0].Instances[0].PublicIpAddress' --output text`

2. Open the Vercel dashboard -> project -> **Settings -> Environment Variables**.

3. Add `VITE_BFF_URL`:
   - Value: the BFF URL resolved above
   - Environments: check both **Production** and **Preview**
   - Click **Save**.

4. Trigger a redeploy: Vercel dashboard -> **Deployments -> ... -> Redeploy** (latest
   production deployment).

5. Confirm the build log contains:
   ```
   VITE_BFF_URL=http://...
   ```

## Verification

After setting the env var, verify the Vercel frontend can reach the BFF:

1. Open the deployed Vercel URL.
2. Open browser DevTools -> Network.
3. Enter an API key in the settings panel.
4. Confirm requests to `/api/v1/...` succeed (200 OK) and originate from the correct
   BFF URL.
5. Confirm the BFF health endpoint responds: `curl http://<EC2-IP>/health`

## Env var value by phase

| Phase | VITE_BFF_URL value |
|---|---|
| Phase 2 (current, no domain) | `http://<EC2-public-IP>/api/v1` |
| Phase 3+ (domain + TLS, #977) | `https://api.mtga-companion.com/api/v1` |

The EC2 public IP is elastic (re-allocates if instance is stopped/started without an
Elastic IP). If the IP changes, re-run the workflow. Purchasing an Elastic IP or a
domain is the permanent fix.
