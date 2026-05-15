# Sync Lambda Deployment

## Overview

The sync Lambda is built from the **app repo** (`RdHamilton/MTGA-Companion`) source on each deploy.
The deploy workflow (`deploy-sync-lambda.yml`) checks out a **pinned app-repo ref** (tag, branch, or SHA)
and compiles `services/sync/cmd/lambda/` into a `bootstrap` binary for AWS Lambda (arm64).

## Pinned App-Repo Ref

The deploy workflow checks out the app repo at a fixed ref rather than the default branch (`main`).
This makes Lambda deployments reproducible and auditable: every deploy is traceable to a known
commit in the app repo.

**Current pinned ref:** `v0.3.0`

This value is hardcoded in two places in `deploy-sync-lambda.yml`:
1. The `workflow_dispatch` input default (`app_repo_ref: "v0.3.0"`)
2. The `ref:` expression fallback used by `repository_dispatch` events

## Advancing the Pinned Ref (Release Runbook)

Perform these steps each time a new app-repo release is cut **before** triggering the infra deploy:

1. Verify the new release tag exists in the app repo:
   ```
   gh release view <new-tag> --repo RdHamilton/MTGA-Companion
   ```
2. Update `deploy-sync-lambda.yml` in this repo — change **both** occurrences of the old tag to the new tag:
   - Line: `default: "v0.3.0"` → `default: "<new-tag>"`
   - Line: `ref: ${{ ... || 'v0.3.0' }}` → `ref: ${{ ... || '<new-tag>' }}`
3. Also update the `name:` expression fallback on the job so the run title reflects the new default.
4. Commit, push, and open a PR to this infra repo. Merge before triggering the Lambda deploy.
5. Trigger the workflow:
   - **Automated (recommended)**: the app repo's release workflow sends a `repository_dispatch` event with type `sync-lambda-deploy` automatically. The workflow will use the updated pinned ref.
   - **Manual**: use `workflow_dispatch` in the GitHub UI and enter the new tag in the `app_repo_ref` field.

## Path Guard

Immediately after checkout, the workflow runs a path-existence check:

```
services/sync/cmd/lambda
```

If this directory is not found (e.g., the Lambda source was relocated in the app repo), the workflow
fails with a clear error message before any build steps run. **Never remove this guard.**

## Why Not Build from `main`?

Building from `main` introduces silent-failure risk: if the `services/sync` directory layout changes
in the app repo (e.g., `cmd/lambda/` relocated), a deploy from `main` would either silently produce
a stale binary or fail with a confusing build error mid-pipeline. Pinning to a tagged release ensures
that every infra deploy is tied to a known, auditable app-repo state consistent with what was tested
and released.
