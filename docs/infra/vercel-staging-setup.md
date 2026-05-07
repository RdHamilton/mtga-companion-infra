# Vercel Preview Environment Configuration — Staging

This document describes the exact Vercel dashboard configuration needed to wire
Vercel PR preview builds to the staging BFF (`staging-api.vaultmtg.app`).

Once configured, every PR preview build will automatically talk to the staging
backend and use the Clerk Development instance — isolating test traffic from
production data. This resolves the ADR-006 risk of preview deploys mutating
production data.

---

## Project

**Vercel project**: MTGA Companion SPA (linked to `RdHamilton/MTGA-Companion`)

---

## Environment: Preview

In the Vercel project dashboard, navigate to **Settings > Environment Variables**
and add the following variables scoped to the **Preview** environment only:

| Variable | Value | Notes |
|---|---|---|
| `VITE_BFF_URL` | `https://staging-api.vaultmtg.app/api/v1` | Routes all API calls in preview builds to the staging BFF |
| `VITE_CLERK_PUBLISHABLE_KEY` | `pk_test_*` | Clerk Development instance key — fill in the real value from the Clerk dashboard |
| `VITE_SENTRY_DSN` | (same as Production value) | Same Sentry project; `environment: staging` tag differentiates in the Sentry UI |

> Ray action: Fill in the real `pk_test_*` value from the Clerk dashboard
> (Development instance > API Keys). Do not copy the `pk_live_*` value.

---

## Environment: Production

These values should already be set. Confirm they are scoped to **Production only**:

| Variable | Value |
|---|---|
| `VITE_BFF_URL` | `https://api.vaultmtg.app/api/v1` |
| `VITE_CLERK_PUBLISHABLE_KEY` | `pk_live_*` |
| `VITE_SENTRY_DSN` | Production DSN from SSM `/vaultmtg/prod/sentry-spa-dsn` |

---

## Environment: Development

These are used when running `vercel dev` locally. Leave unset or configure to
point at a local BFF (`http://localhost:8080/api/v1`).

---

## Steps

1. Open the Vercel dashboard: https://vercel.com/rdhamiltong/mtga-companion
2. Go to **Settings > Environment Variables**.
3. For each variable in the Preview table above:
   a. Click **Add New**.
   b. Set **Environment** to **Preview** (deselect Production and Development).
   c. Enter the variable name and value.
   d. Save.
4. Trigger a new preview deployment by opening a test PR (or re-deploying an
   existing one from the Vercel dashboard).
5. In the preview build logs, confirm `VITE_BFF_URL` resolves to
   `https://staging-api.vaultmtg.app/api/v1`.
6. In the preview build, open the browser network tab and confirm API calls
   go to `staging-api.vaultmtg.app`, not `api.vaultmtg.app`.

---

## Notes

- These overrides apply only to **Preview** deployments (PR builds). Production
  deployments continue to use `api.vaultmtg.app`.
- The Vercel preview domain glob (`https://*.vercel.app`) is already included in
  the staging BFF `ALLOWED_ORIGINS` SSM parameter
  (`/mtga-companion/staging/ALLOWED_ORIGINS`), so CORS is pre-configured.
- If you use a custom Vercel preview domain alias (e.g.
  `staging.vaultmtg.app`), add it to the `ALLOWED_ORIGINS` SSM parameter:
  ```
  aws ssm put-parameter \
    --name /mtga-companion/staging/ALLOWED_ORIGINS \
    --value "https://staging-api.vaultmtg.app,https://*.vercel.app,https://staging.vaultmtg.app" \
    --type String --overwrite --region us-east-1 --profile personal
  ```
  Then re-deploy the staging BFF to pick up the new value.

---

## Related

- ADR: `docs/adr/staging-environment-design.md`
- Staging nginx config: `nginx/staging-api.vaultmtg.app.conf` (in infra repo)
- Staging systemd unit: `systemd/mtga-companion-staging.service` (in infra repo)
- Staging deploy workflow: `.github/workflows/staging-deploy.yml` (in app repo)
- SSM parameters: `/vaultmtg/staging/*` and `/mtga-companion/staging/*`
