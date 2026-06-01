# Meta-Scrape Lambda Deployment

## Overview

The meta-scrape Lambda is built from the **app repo** (`RdHamilton/vault-mtg`) source on each deploy.
The deploy workflow (`deploy-meta-scrape-lambda.yml`) checks out an app-repo ref and compiles
`services/meta-scrape/cmd/lambda/` into a `bootstrap` binary for AWS Lambda (arm64).

It populates the `mtgzone_archetypes` table that backs the prod Meta page. The function runs daily at
03:00 UTC via an EventBridge schedule (offset one hour after the 02:00 sync Lambda to avoid NAT/RDS
contention — ADR-044).

There are **two** moving parts, each owned by a different workflow:

| Concern                                            | Owner                              |
| -------------------------------------------------- | ---------------------------------- |
| Build + create/update the Lambda **function code** | `deploy-meta-scrape-lambda.yml`    |
| IAM role, VPC config, env vars, DLQ, schedule, alarms (CFN stack `mtga-companion-meta-scrape-lambda`) | `deploy.yml` (stack `meta-scrape-lambda`) |

This mirrors the sync Lambda split (see `sync-lambda-deploy.md`): the deploy workflow owns the binary;
the CloudFormation stack owns everything around it. The CFN template's `LambdaVpcConfigCustomResource`
runs `update_function_configuration` against an **already-existing** function — it does not create the
function itself.

## Pinned App-Repo Ref

`deploy-meta-scrape-lambda.yml` defaults to `main` (not a tag) because the meta-scrape Lambda source
merged into the app repo **after** the `v0.3.4` release tag — no tagged release yet contains it. Once a
release tag does contain `services/meta-scrape/cmd/lambda/`, advance the `app_repo_ref` default to that
tag for reproducibility (see the sync Lambda runbook for the tag-advance procedure).

A path guard immediately after checkout fails the workflow if `services/meta-scrape/cmd/lambda` is
absent — never remove it.

## First-Time Deploy Ordering (IMPORTANT)

There is a genuine ordering dependency between the function and the stack:

- `deploy-meta-scrape-lambda.yml`'s `create-function` step needs the execution role ARN
  (`vaultmtg-${Environment}-meta-scrape-lambda-role`), which is created **by the CFN stack**.
- The CFN stack's `LambdaVpcConfigCustomResource` configures the **function**, which is created **by the
  workflow**.

If the custom resource hard-failed when the function was absent, a first-ever stack CREATE would roll
back and delete the role it had just created — so neither "function first" (no role) nor "stack first"
(custom resource fails → rollback deletes role) could succeed cleanly. This is the circular dependency
that previously blocked the meta-scrape deploy.

**Resolution (this PR):** the custom resource is now tolerant of a not-yet-existing function. On the
first stack CREATE it calls `get_function`; if the function is absent it returns `SUCCESS` as a no-op,
so the stack finishes creating the role and all surrounding infra. VPC config is applied on the next
stack pass once the function exists. This makes BOTH orderings converge.

Cold-start sequence:

1. **Create the SSM SecureString credential** (one-time, out-of-band). The stack injects only the
   SecureString *path* (`DB_PASSWORD_SSM_PATH`); the Lambda fetches and decrypts the password at runtime
   (ADR-044, ticket 341). The parameter must already exist as `Type=SecureString`:
   ```
   aws ssm get-parameter --name /vaultmtg/app/production/meta-scrape-db-password \
     --query 'Parameter.Type' --profile personal --region us-east-1
   # -> SecureString
   ```
2. **Deploy the stack** — `deploy.yml` with `stack=meta-scrape-lambda`. Creates the IAM role, security
   group, DLQ, schedule, and alarms. The custom resource no-ops (function not yet present) and the stack
   reaches `CREATE_COMPLETE`.
3. **Create the function** — run `deploy-meta-scrape-lambda.yml` (`workflow_dispatch`). `create-function`
   now finds the role created in step 2 and creates `vaultmtg-meta-scrape`.
4. **Re-run the stack** — `deploy.yml stack=meta-scrape-lambda` once more. The custom resource now finds
   the function and applies VPC config + env vars (`DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PORT`,
   `DB_PASSWORD_SSM_PATH`). The schedule begins invoking the now-configured function.

Subsequent deploys are single-pass in either order, because both the role and the function already exist.

## Subsequent Updates

- **Code change only:** run `deploy-meta-scrape-lambda.yml`. The `if` branch runs
  `update-function-code` + `wait function-updated`.
- **Infra change (env vars, schedule, alarms, IAM):** run `deploy.yml stack=meta-scrape-lambda`. The
  custom resource re-applies VPC/env config to the existing function.
- Either workflow is safe to run independently once both the role and function exist.

## Staging

`deploy.yml stack=meta-scrape-lambda-staging` resolves to stack `vaultmtg-meta-scrape-lambda-staging`
using the same `meta-scrape-lambda.yml` template with `cloudformation/parameters/meta-scrape-lambda-staging.json`
(staging SSM paths, `vaultmtg-meta-scrape-staging` function name). The staging SecureString
`/vaultmtg/app/staging/meta-scrape-db-password` must exist before deploying the staging stack.

## Drift Detection

`mtga-companion-meta-scrape-lambda` is registered in `detect-drift.yml`'s `ALL_STACKS`, so it is covered
by the scheduled drift sweep alongside the sync Lambda stack.
