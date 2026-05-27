# Missed-Cousin Auditor

**Status:** ACTIVE  
**Owner:** Ray (Architect / Infrastructure)  
**Ticket:** vault-mtg-tickets#52  
**Effective:** 2026-05-27

---

## Why This Exists

During Phase 1 of the staging-environment separation (2026-05-27), four back-to-back "missed cousin" failures cost roughly 30 minutes each. The pattern: a NEW resource is created with a NEW identifier (RDS instance, SG, secret, GHA environment name), but other IAM/policy/SG configs that must reference that identifier were not updated at the same time.

The four specific failures:

| # | PR fixed | What was missed | Root resource (PR #238) |
|---|---|---|---|
| 1 | #239 | `GhaInfraCfnDeployRole` trust lacked `:environment:staging` sub | `deploy.yml` added `environment: staging` routing |
| 2 | #240 | Staging RDS SG ingress used phantom SG `sg-09f07e050f807c733` instead of the real EC2 SG | New `AWS::EC2::SecurityGroup` in `rds-vaultmtg-staging.yml` + parameter |
| 3 | #241 | `vaultmtg-staging-deploy-provisioner` inline policy lacked `GetSecretValue` on the new staging RDS secret | New `AWS::RDS::DBInstance` with `ManageMasterUserPassword: true` |
| 4 | #243 | `GhaInfraSyncDeployRole` trust ALSO missed `:environment:staging` | Same deploy.yml environment routing as failure #1 |

All four fixes were reactive. This auditor makes them proactive by emitting warnings on the NEW-resource PR before merge.

---

## Implementation Approach

**Script + workflow:** `scripts/ci/audit-cousins.sh` + `.github/workflows/missed-cousin-auditor.yml`.

**Rationale for script-not-workflow-inline:** The heuristic logic is moderately complex (multi-pass template scanning, cross-file correlation). Keeping it in a bash script makes it:
- Directly testable locally (`bash scripts/ci/audit-cousins.sh cloudformation/rds-vaultmtg-staging.yml`)
- Independently auditable in diff without workflow YAML noise
- Invocable in future contexts beyond a PR (e.g., a pre-deploy gate or manual scan)

**Trigger:** Every PR to `main` (no label required). The auditor detects which CFN templates changed, applies cousin-class heuristics only to those templates, and exits `0` whether it found gaps or not (warnings only, not hard-fail — see "Emit warnings, not hard-fails" below).

**Emit warnings, not hard-fails:** This is a flag-and-suggest tool. Engineers may have intentional reasons not to update a cousin (e.g., the staging environment trust entry was intentionally not added yet because Phase 6 hasn't landed). A hard-fail would block legitimate PRs. The output is a PR comment listing each gap with file + suggested fix. Future work (tracked as follow-on) can flip individual cousin-class checks to hard-fail once false-positive rates are understood.

**Out of scope:** Cross-repo cousin checks (e.g., a new environment name in `iam-gha-roles.yml` that also needs updating in `vault-mtg`'s deploy workflows). Cross-repo detection requires GitHub API access to the other repo's content and is deferred.

---

## Cousin-Class Heuristic Rules

### Class A: New GHA environment name

**Trigger:** A new `environment:` sub-claim entry is added to any IAM role's trust policy in `iam-gha-roles.yml`.

**Cousins to check:**
- All OTHER `GhaInfra*Role` trust policies in `iam-gha-roles.yml` — do they also need the new environment sub?
- `staging-deploy-role.yml` trust `GitHubOIDCTrust` — does it need the new sub?

**Detection heuristic:** Extract all distinct `environment:<name>` sub-claim values from the CHANGED template. For each newly added env name, grep all OTHER IAM role trust policies in the repo for that env name. Missing entries are candidate gaps.

**Example failure caught:** PR #239 (GhaInfraCfnDeployRole) and PR #243 (GhaInfraSyncDeployRole) would both be flagged on PR #238 — the PR that added the `staging` environment routing in `deploy.yml`.

---

### Class B: New RDS instance with managed secret

**Trigger:** A new `AWS::RDS::DBInstance` resource with `ManageMasterUserPassword: true` appears in a changed CFN template.

**Cousins to check:**
- `staging-deploy-role.yml` `StagingDBSecretRead` policy — does it have a `GetSecretValue` grant for the new secret ARN prefix (`rds!db-<instance-id>-*`)?

**Detection heuristic:** The secret ARN prefix is `rds!db-<db-resource-id>-*` where the resource ID is not knowable at PR time (it's assigned by RDS at launch). The auditor checks whether `staging-deploy-role.yml` has ANY `rds!db-*` grant in its `StagingDBSecretRead` statement. If the PR adds a new `AWS::RDS::DBInstance` with `ManageMasterUserPassword: true` and `staging-deploy-role.yml` does NOT include a new `rds!db-` entry in the same PR diff, flag it.

**Note:** The exact ARN (`rds!db-55ac0968-...`) is only known post-deploy. The auditor flags the PATTERN gap ("staging-deploy-role.yml should get a new rds!db-* grant for this instance"), not the exact ARN. The engineer resolves it post-first-deploy by updating the grant with the real resource ID.

**Example failure caught:** PR #241 would be flagged on PR #238.

---

### Class C: New EC2 security group used as RDS/EC2 ingress source

**Trigger:** A new `AWS::EC2::SecurityGroup` appears in a changed CFN template, OR a parameter file changes a `*SecurityGroupId` parameter value.

**Cousins to check:**
- ALL other CFN stacks in the repo that reference `*SecurityGroupId` parameters — do any of them point to a stale/phantom SG ID?
- Specifically: if the PR changes a `*EC2SecurityGroupId` parameter, check whether related RDS stacks reference the same SG.

**Detection heuristic:** If a parameters JSON file is changed and the changed value matches a pattern like `sg-[0-9a-f]{17}`, grep all parameter files and template `SecurityGroupIngress` sections for the OLD value. If any still reference the old SG ID without a corresponding update in this PR, flag it.

**Example failure caught:** PR #240 (`rds-vaultmtg-staging.json` parameter changed from phantom `sg-09f07e050f807c733` to real `sg-020b7705a72e9f246`). The auditor would flag on PR #238 that `EC2SecurityGroupId` was set to a non-existent SG.

---

### Class D: New GHA environment routing in deploy.yml

**Trigger:** `deploy.yml` is changed to add a new `environment:` routing branch (e.g., a new `contains(inputs.stack, 'staging')` conditional or explicit environment name).

**Cousins to check:**
- All `GhaInfra*Role` trust policies in `iam-gha-roles.yml` — do they include the new environment sub?
- `staging-deploy-role.yml` trust `GitHubOIDCTrust` — does it include the new environment sub?

**Detection heuristic:** Extract all `environment:` values from the `deploy.yml` diff (lines starting with `+`). For each new environment name, grep `iam-gha-roles.yml` and `staging-deploy-role.yml` for that env name. Missing entries are candidate gaps.

**Note:** This class overlaps with Class A but triggers from the WORKFLOW side rather than the IAM template side, catching the case where deploy.yml adds a new environment but neither IAM file was updated.

---

## Run Mode

The auditor runs on every PR to `main` in `mtga-companion-infra`. No label required.

**Rationale:** Almost every infra PR changes a CFN template, and the cousin-class heuristics only activate when specific resource types appear in the diff. The cost of running on a non-triggering PR is a single git-diff + grep pass — under 5 seconds. Requiring a label would mean the auditor only runs when someone remembers to add the label, which defeats the purpose.

**Output:** A PR comment posted via `gh pr comment` listing each gap with:
- Which cousin class fired
- Which file is the trigger
- Which file/resource is the suspected gap
- A one-line suggested fix

If no gaps are detected, the comment is NOT posted (no noise on clean PRs).

---

## Backtest Results

The auditor was validated against the four known-fix PRs. Because those PRs ARE the fix, the backtest scenario is: "would the auditor have flagged the gap if run on PR #238 (the new-resource PR, base: commit `c7e6747`, head: commit `e80871b`) before merge?"

Command used:

```
$ CHANGED_TEMPLATES="cloudformation/rds-vaultmtg-staging.yml .github/workflows/deploy.yml" \
    DIFF_BASE_OVERRIDE="c7e6747" \
    bash scripts/ci/audit-cousins.sh

[audit-cousins] Scan complete. Gaps found: 2

### Gap #1 -- Class B (New RDS managed secret)
Trigger: cloudformation/rds-vaultmtg-staging.yml
Suspected gap in: cloudformation/staging-deploy-role.yml

### Gap #2 -- Class D (New GHA environment, IAM trust not updated)
Trigger: .github/workflows/deploy.yml
Suspected gap in: cloudformation/iam-gha-roles.yml
```

| Failure | Class | Caught? | Notes |
|---|---|---|---|
| #1 GhaInfraCfnDeployRole missing `:environment:staging` | D | YES — Gap #2 | iam-gha-roles.yml flagged; both roles are in the same file |
| #2 Phantom SG `sg-09f07e050f807c733` in parameters | C | NO | Class C detects replaced SG values in an existing params file. PR #238 ADDED a new params file with the phantom SG already in it — no "old" value to detect. Detecting a phantom value requires AWS validation (aws ec2 describe-security-groups), which is out of scope for a diff-only auditor. Documented limitation. |
| #3 Provisioner missing GetSecretValue on new RDS secret | B | YES — Gap #1 | staging-deploy-role.yml flagged correctly |
| #4 GhaInfraSyncDeployRole missing `:environment:staging` | D | YES — Gap #2 | Same iam-gha-roles.yml gap covers both roles |

**3 of 4 failures caught.** The phantom SG (failure #2) is a known limitation: Class C requires an existing params file to be modified; it cannot detect a wrong SG value in a newly created file without AWS API validation.

Zero gaps on current main (all fixes applied):

```
$ CHANGED_TEMPLATES="cloudformation/rds-vaultmtg-staging.yml .github/workflows/deploy.yml" \
    DIFF_BASE_OVERRIDE="c7e6747" \
    bash scripts/ci/audit-cousins.sh

[audit-cousins] Scan complete. Gaps found: 0
```

PASS — auditor correctly clears after all fixes are applied.

---

## File Locations

| File | Purpose |
|---|---|
| `.github/workflows/missed-cousin-auditor.yml` | CI workflow — fires on every PR to main |
| `scripts/ci/audit-cousins.sh` | Heuristic scanner — called by the workflow |
| `vault-mtg-docs/engineering/runbooks/missed-cousin-auditor.md` | This design doc |

---

## Follow-On Work

- Flip individual cousin-class checks from warn to hard-fail once false-positive rates are established (suggest: after 10 clean PR cycles on Class B and D).
- Class E: new SSM parameter namespace — check whether IAM roles that read SSM have been updated to include the new path prefix.
- Cross-repo audit for deploy workflow environment names that also need IAM updates in `mtga-companion-infra`.
