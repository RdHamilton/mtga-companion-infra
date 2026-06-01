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
the CloudFormation stack owns everything around it. The CFN template's function-dependent resources
(the `LambdaVpcConfigCustomResource`, the EventBridge schedule + invoke permission, the
`AWS::Lambda::EventInvokeConfig`, and the function-metric alarms) all assume an **already-existing**
function — they do not create the function itself, and are gated behind the `FunctionExists` Condition
(see "First-Time Deploy Ordering" below).

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

On a first-ever stack CREATE the function cannot exist yet, so any resource that references it by
name/ARN fails. There are **five** such resources, not one:

1. `LambdaVpcConfigCustomResource` — `update_function_configuration` against the function.
2. `MetaScrapeLambdaEventInvokeConfig` (`AWS::Lambda::EventInvokeConfig`) — `PutFunctionEventInvokeConfig`
   returns `404 NotFound` when the function is absent. **This is what rolled back the first real deploy
   (Pass 1).**
3. `LambdaPermissionScheduler` (`AWS::Lambda::Permission`) — `AddPermission` requires the function.
4. `DailyMetaScrapeSchedule` (`AWS::Scheduler::Schedule`) — its `Target.Arn` is the function ARN and
   EventBridge Scheduler validates the target at create time. (A schedule has no valid form without a
   target, so the whole schedule is gated.)
5. `MetaScrapeLambdaErrorAlarm` / `MetaScrapeLambdaZeroInvocationsAlarm` — keyed on the
   `FunctionName` metric dimension; meaningless before the function exists.

An earlier fix made only resource (1) tolerant of an absent function, which is why each deploy
attempt surfaced the *next* function-dependent resource (whack-a-mole). The DLQ-depth alarm is **not**
in this list — it is keyed on the DLQ's `QueueName`, so it is valid from the first pass.

**Resolution (this PR):** a single template parameter `FunctionExists` (default `false`) backs a
`Conditions.FunctionExists` Condition that gates **all** function-dependent resources (and their
Outputs) as one deterministic switch. `deploy.yml` derives the value from the changeset type, so there
is no manual flag to flip:

- **CREATE → `FunctionExists=false`** — Pass 1 creates only the function-independent infra (security
  group, RDS ingress, execution role, scheduler role, DLQ, DLQ policy, DLQ-depth alarm) and reaches
  `CREATE_COMPLETE`. None of the function-dependent resources are attempted, so there is nothing left
  to whack.
- **UPDATE → `FunctionExists=true`** — once the function has been created out-of-band, the next stack
  deploy is an UPDATE and CFN creates the gated resources (EventInvokeConfig, schedule + target,
  invoke permission, VPC config, alarms) against the now-existing function.

This also removes the previous per-resource tolerance hack inside the custom-resource handler: the
custom resource now only ever runs when the function is guaranteed present.

Cold-start sequence:

1. **Create the SSM SecureString credential** (one-time, out-of-band). The stack injects only the
   SecureString *path* (`DB_PASSWORD_SSM_PATH`); the Lambda fetches and decrypts the password at runtime
   (ADR-044, ticket 341). The parameter must already exist as `Type=SecureString`:
   ```
   aws ssm get-parameter --name /vaultmtg/app/production/meta-scrape-db-password \
     --query 'Parameter.Type' --profile personal --region us-east-1
   # -> SecureString
   ```
2. **Deploy the stack (Pass 1)** — `deploy.yml` with `stack=meta-scrape-lambda`. This is a CREATE, so
   `deploy.yml` injects `FunctionExists=false`. It creates the IAM role, security group, RDS ingress,
   scheduler role, DLQ, DLQ policy, and DLQ-depth alarm, and reaches `CREATE_COMPLETE`. No
   function-dependent resource is attempted.
3. **Create the function (Pass 2)** — run `deploy-meta-scrape-lambda.yml` (`workflow_dispatch`).
   `create-function` now finds the role created in step 2 and creates `vaultmtg-meta-scrape`.
4. **Re-run the stack (Pass 3)** — `deploy.yml stack=meta-scrape-lambda` once more. This is now an
   UPDATE, so `deploy.yml` injects `FunctionExists=true`, and CFN creates the schedule + target, invoke
   permission, EventInvokeConfig, the VPC-config custom resource (which applies VPC config + env vars
   `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PORT`, `DB_PASSWORD_SSM_PATH`), and the function-metric alarms.
   The schedule begins invoking the now-configured function.

Subsequent deploys are single-pass, because the stack already exists (UPDATE → `FunctionExists=true`)
and both the role and the function are present.

## Subsequent Updates

- **Code change only:** run `deploy-meta-scrape-lambda.yml`. The `if` branch runs
  `update-function-code` + `wait function-updated`.
- **Infra change (env vars, schedule, alarms, IAM):** run `deploy.yml stack=meta-scrape-lambda`. The
  custom resource re-applies VPC/env config to the existing function.
- Either workflow is safe to run independently once both the role and function exist. Because the
  stack already exists, every such infra deploy is an UPDATE → `FunctionExists=true`, so the
  function-dependent resources stay in place.

## Staging

`deploy.yml stack=meta-scrape-lambda-staging` resolves to stack `vaultmtg-meta-scrape-lambda-staging`
using the same `meta-scrape-lambda.yml` template with `cloudformation/parameters/meta-scrape-lambda-staging.json`
(staging SSM paths, `vaultmtg-meta-scrape-staging` function name). The staging SecureString
`/vaultmtg/app/staging/meta-scrape-db-password` must exist before deploying the staging stack.

## Drift Detection

`mtga-companion-meta-scrape-lambda` is registered in `detect-drift.yml`'s `ALL_STACKS`, so it is covered
by the scheduled drift sweep alongside the sync Lambda stack.
