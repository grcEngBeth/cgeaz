# CGE-AZ GRC Engineering Pipeline (capstone fork)

The capstone for **CGE-AZ: Certified GRC Engineer — Azure Specialty** (GRC Engineering
Club Training Academy), built from the course starter and extended. It is a complete,
automated GRC engineering pipeline running in one Azure sandbox subscription:

```
1 Discovery → 2 Activation → 3 Evidence Store → 4 Reporting → 6 Enforcement ↺
   detect        enable         Cosmos + WORM      SAR/POA&M     Azure Policy
   what runs     what's         Blob + collectors  from the      + remediation
                 missing        (Functions)        store ONLY    identity (dry-run)
```

Stage 5 (the AI narrative digest) is optional in the course and is **not built** in this
fork; there is no `stages/05-*`.

Every finding comes from Defender for Cloud or Azure Policy, is stored as a document in
Cosmos DB with a run ID, and reaches the POA&M and SAR only through that store. Reports
are written once to an immutable (WORM) container. Changes reach Azure only through
pull requests that pass a conftest gate, and a nightly drift run opens an issue when
Azure stops matching the code.

## Where to read

| File | What it covers |
|---|---|
| This README | Deploying the whole pipeline from an empty subscription, in order |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Stage flow, data flow, identity boundaries, every change from the starter (section 5) |
| [docs/CONTROLS.md](docs/CONTROLS.md) | Every policy, collector and gate rule mapped to NIST CSF 2.0, with blast radius and the off switch for each enforcement policy |
| [docs/SETUP.md](docs/SETUP.md) | The course's one-time setup: free account, regional quirks, cost guardrails |
| [docs/VALIDATION-LOG.md](docs/VALIDATION-LOG.md) | What broke in the course's own validation runs |
| [queries/privileged-role-assignments.sql](queries/privileged-role-assignments.sql) | The stored query behind the privileged-access numbers in CONTROLS.md |

## What this fork adds to the starter

The full list, with the reasoning and PR for each, is in ARCHITECTURE.md section 5. In short:

- **Least-privilege identities.** CI plans with a custom read-only role
  (`cge-ci-planner`) instead of Contributor; the remediation identity uses a custom role
  (`cge-remediation-storage-writer`) that cannot delete accounts or list keys; the
  reporter and the human deployer have narrower data-plane scopes; no basic-auth
  publishing on either Function App.
- **An own policy and gate rule.** `cge-require-secure-transfer` (Audit) in Azure, and
  `policy/transport.rego` (HTTPS-only, TLS 1.2+) in the gate, its code-side twin.
- **A role-assignment collector.** Nightly, into the Cosmos `identities` container, so
  privileged access is reported from stored evidence
  ([queries/](queries/privileged-role-assignments.sql)).
- **Honest CI.** Drift now opens an issue when it finds drift (the starter's wrapper hid
  it); the gate also covers stage 02, blocks User Access Administrator and RBAC
  Administrator grants, and runs a digest-pinned conftest image.
- **Owners and telemetry.** Every POA&M item carries its resource group's owner tag (or
  `UNASSIGNED`); both Function Apps send telemetry to Application Insights with their
  managed identity.

## Deploy from an empty subscription

This is the whole build in order, about 1–2 hours of work plus waits. Run every command
from the repo root unless a step says otherwise. The commands assume macOS or Linux; on
Windows read [docs/SETUP.md](docs/SETUP.md) section 7 first.

Commands are written to paste into zsh or bash. They have no `#` comment lines on purpose:
interactive zsh runs a pasted `#` line as a command.

### 0. Tools and a clean clock

You need the Azure CLI (deploys with basic auth off were tested on 2.91), Terraform 1.9 or
later, Python 3.11+, `git`, the GitHub CLI `gh`, and `zip`. Fork this repo to your own
GitHub account and clone your fork.

Check the clock first. A clock that is a few minutes off makes Azure Storage refuse every
signed request with `AuthenticationFailed`:

```bash
date -u
```

Compare it with real UTC. If it is off, fix the system clock before going further.

### 1. Sign in, register providers, set a budget

```bash
az login
az account show --query "{name:name, id:id}" -o table
./labs/00-setup/register-providers.sh
./labs/01-sandbox/create-budget.sh you@example.com
./labs/00-setup/probe-quota.sh
```

- `register-providers.sh` registers the 11 resource providers the pipeline and the seed
  estate use, and waits for them.
- `create-budget.sh` creates a $10/month budget with alerts. Use an address you actually
  read: the budget lives in Azure, not in this repo.
- `probe-quota.sh` finds the regions where a free account can host consumption (Y1)
  Function Apps. Stages 03 and 04 default to `centralus`. If the probe does not mark
  `centralus` OK, pick a region it does mark OK and run
  `export TF_VAR_functions_location=<region>` in every terminal you deploy from.

### 2. Set the session variables

Terraform reads these from the environment. Set them in **every new terminal** before
running any stage:

```bash
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export OWNER_EMAIL=grc-sandbox-owner@example.com
export TF_VAR_owner_email="$OWNER_EMAIL"
export TF_VAR_deployer_principal_id="$(az ad signed-in-user show --query id -o tsv)"
```

`OWNER_EMAIL` becomes the owner tag on governed resource groups and the owner of
subscription-level POA&M items. Use a role mailbox, never a personal address: it is
written into tags, Terraform state and CI variables.

`TF_VAR_deployer_principal_id` is you. It gets read access to the evidence store and
write access to the reference-data containers only. CI sets the same value, so plans do
not change depending on who runs them.

### 3. Bootstrap the Terraform state store

```bash
./labs/03-foundation/bootstrap.sh
export TF_VAR_state_storage_account="$(grep storage_account_name labs/03-foundation/backend.hcl | cut -d'"' -f2)"
```

This creates `rg-grc-tfstate` and a versioned state storage account (TLS 1.2, no public
blob access) tagged with the owner. It grants you Storage Blob Data Contributor on it and
writes `labs/03-foundation/backend.hcl`, which is gitignored. State is the one piece that
cannot manage itself, so it is a script and not Terraform. Add the `export` line to your
terminal setup from step 2 from now on.

Wait 1–3 minutes before the first `terraform init`. The data-plane role bootstrap just
granted takes that long to work. An init that fails with 403
`AuthorizationPermissionMismatch` means wait and retry, not add more roles.

### 4. Stage 01: foundation

```bash
cd stages/01-foundation
terraform init -backend-config=../../labs/03-foundation/backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
cd ../..
```

This creates the management groups `mg-grc` and `mg-grc-sandbox`, `rg-grc-sandbox-dev`,
the Log Analytics workspace `law-grc-sandbox`, `rg-grc-evidence-dev`, the
`cge-grc-baseline` policy initiative and its assignment, and the user-assigned
remediation identity. In an empty subscription there is nothing to import: the course
labs had you make some of these by hand first, and this build lets Terraform create them.

Check that the subscription sits under `mg-grc-sandbox`, where the baseline is assigned:

```bash
az account management-group subscription show --name mg-grc-sandbox --subscription "$ARM_SUBSCRIPTION_ID" --query name -o tsv
```

If that reports the subscription is not found, add it, then wait a few minutes for
policy to evaluate:

```bash
az account management-group subscription add --name mg-grc-sandbox --subscription "$ARM_SUBSCRIPTION_ID"
```

Then create the two pieces Terraform does not own. Neither is watched for drift, which is
noted in CONTROLS.md:

```bash
./labs/02-toolkit/route-activity-log.sh
az ad group create --display-name grc-auditors --mail-nickname grc-auditors
az role assignment create --assignee-object-id "$(az ad group show --group grc-auditors --query id -o tsv)" --assignee-principal-type Group --role Reader --scope "/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/rg-grc-sandbox-dev"
```

### 5. Stage 02: activation

```bash
cd stages/02-activation
terraform init -backend-config=../../labs/03-foundation/backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
terraform output
cd ../..
```

This sets the baseline Defender for Cloud plans to Standard and assigns the NIST CSF 2.0
standard (`nist-csf-20`) at the subscription. `current_plan_tiers` and
`activation_needed` in the output are the plan-coverage inventory.

Two clocks start here. Each Defender plan has a 30-day free trial from first enablement.
On a new subscription, Defender's first assessments take several hours, up to about 24.
The collector handles an empty result as a clean run of 0 documents.

### 6. Stage 03: evidence store and collectors

```bash
cd stages/03-evidence-store
terraform init -backend-config=../../labs/03-foundation/backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
cd ../..
```

This creates the Cosmos DB account (Entra-only, local auth off) with the `grc` database
and the `assessments`, `identities`, `frameworks` and `mappings` containers. It also
creates the evidence storage account (no shared keys) with the WORM `reports` container,
the collector Function App with its Application Insights, and the collector's scoped role
grants. Cosmos takes several minutes.

If Cosmos fails with `ServiceUnavailable ... high demand`, the region is out of capacity.
Run `export TF_VAR_location=<another region>` and apply again.

### 7. Deploy the collector code

```bash
APP="$(cd stages/03-evidence-store && terraform output -raw collector_function_app)"
rm -f /tmp/collector.zip
(cd functions/collect_assessments && zip -r /tmp/collector.zip . -x '*__pycache__*')
az functionapp deployment source config-zip --name "$APP" --resource-group rg-grc-evidence-dev --src /tmp/collector.zip --build-remote true --timeout 600
az rest --method post --url "https://management.azure.com/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/rg-grc-evidence-dev/providers/Microsoft.Web/sites/$APP/syncfunctiontriggers?api-version=2022-03-01"
az functionapp function list --name "$APP" --resource-group rg-grc-evidence-dev --query "[].name" -o tsv
```

- **`rm -f`:** `zip` adds to an existing archive, so deleting the old one first stops
  stale files riding along.
- **The deploy:** remote build holds the terminal while it installs dependencies. It
  authenticates with your Entra ID, because basic-auth publishing is off on both
  Function Apps.
- **`syncfunctiontriggers`:** without it, the function list kept showing the previous
  deploy's functions even though the new code was live.
- **The function list:** expect the assessment collector (`collect_nightly`,
  `collect_now`) and the role-assignment collector (its timer and HTTP route).

### 8. Seed the reference data

```bash
python3 -m venv ~/.venvs/cosmos
~/.venvs/cosmos/bin/pip install --only-binary=:all: azure-cosmos azure-identity
export COSMOS_ENDPOINT="$(cd stages/03-evidence-store && terraform output -raw cosmos_endpoint)"
(cd labs/04-evidence && ~/.venvs/cosmos/bin/python seed_frameworks.py)
```

Expected: `seeded 7 framework documents into https://cosmos-grc-evidence-....`

- **The venv** lives in your home folder because macOS cleans `/tmp` and leaves a broken
  venv behind.
- **`--only-binary`** stops `cryptography` trying to compile from source, which fails on
  some Macs.
- **A permission error here** usually means the Cosmos role from stage 03 is still
  taking effect; wait a minute and rerun.

### 9. Stage 04: reporting, then deploy the report code

```bash
cd stages/04-reporting
terraform init -backend-config=../../labs/03-foundation/backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
cd ../..
APP="$(cd stages/04-reporting && terraform output -raw reporting_function_app)"
rm -f /tmp/reports.zip
(cd functions/reports && zip -r /tmp/reports.zip . -x '*__pycache__*')
az functionapp deployment source config-zip --name "$APP" --resource-group rg-grc-evidence-dev --src /tmp/reports.zip --build-remote true --timeout 600
az rest --method post --url "https://management.azure.com/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/rg-grc-evidence-dev/providers/Microsoft.Web/sites/$APP/syncfunctiontriggers?api-version=2022-03-01"
az functionapp function list --name "$APP" --resource-group rg-grc-evidence-dev --query "[].name" -o tsv
```

The function list should show `poam_daily`, `poam_now`, `sar_now` and `sar_weekly`. The
reporter can read `assessments` and write to the `reports` container, and nothing else.
It has no Security Reader and no Cosmos write: collector and reporter are separated by
their scopes.

### 10. Stage 06: enforcement (dry-run)

```bash
cd stages/06-enforcement
terraform init -backend-config=../../labs/03-foundation/backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
terraform output remediation_mode
cd ../..
```

This deploys the fix-public-blob policy at `mg-grc-sandbox` in dry-run (`DoNotEnforce`),
the custom role `cge-remediation-storage-writer`, and its grant to the remediation
identity. Dry-run means the policy flags and a human creates the remediation task.
Moving to `enforce` is its own reviewed PR. CONTROLS.md lists the blast radius and off
switch for every enforcement policy.

### 11. Arm CI on your fork

```bash
./labs/06-loop/arm-your-fork.sh YOUR_GITHUB_USERNAME
```

Replace `YOUR_GITHUB_USERNAME` with your GitHub username.

This creates an OIDC app registration federated to your fork only. It includes the
numeric-ID subjects GitHub now sends, which the starter script lacked, so login failed
with `AADSTS700213`. It also creates and assigns the custom `cge-ci-planner` role at
`mg-grc` and blob data access on the state resource group. Rerunning it is safe: it skips
what exists.

It prints five repository variables. CI needs a sixth, `DEPLOYER_PRINCIPAL_ID`. Set all
six, using the printed values for the first three:

```bash
gh variable set AZURE_CLIENT_ID --body "<printed value>"
gh variable set AZURE_TENANT_ID --body "<printed value>"
gh variable set AZURE_SUBSCRIPTION_ID --body "<printed value>"
gh variable set STATE_STORAGE_ACCOUNT --body "$TF_VAR_state_storage_account"
gh variable set OWNER_EMAIL --body "$OWNER_EMAIL"
gh variable set DEPLOYER_PRINCIPAL_ID --body "$TF_VAR_deployer_principal_id"
gh repo edit --enable-issues
gh label create drift --description "Opened by the nightly drift workflow"
```

These are variables, not secrets: with OIDC there is no stored credential, and the IDs
grant nothing without the fork-scoped federation. Never arm the upstream course repo.
On a public repo, a `pull_request` subject matches PRs from any fork, and the PR can edit
the workflow it runs.

Then, in your fork on GitHub:

1. **Actions tab:** enable workflows. GitHub disables them on forks and can disable them
   again later. The only notice is a banner on this tab.
2. **Settings → Branches:** protect `main`. Require the five gate checks, one per stage,
   and turn on "Do not allow bypassing the above settings", so the owner cannot merge
   around a red gate either.
3. **Test it:** open a test PR and confirm all five gate checks run and pass.

From here on, every change goes branch → PR → gate → merge, never straight to `main`.

### 12. Seed the capstone estate (optional)

```bash
./seed-estate.sh
```

This adds about a dozen cheap resources in `rg-fafo-prod` and `rg-fafo-legacy`, several
deliberately misconfigured, so the reports have real findings. The one public-blob
misconfiguration is refused by the Deny policy, which is the control working. If the F1
App Service plan fails on quota, set `SEED_APP_LOCATION` to another region. Remove it all
with `./seed-estate.sh --teardown`.

## Check that it works

**Code matches Azure.** Every stage should plan with no changes. Exit code 0 means No
changes, 2 means changes, 1 means an error:

```bash
for s in 01-foundation 02-activation 03-evidence-store 04-reporting 06-enforcement; do (cd "stages/$s" && terraform init -input=false -backend-config=../../labs/03-foundation/backend.hcl >/dev/null && terraform plan -detailed-exitcode -input=false >/dev/null; echo "$s: exit $?"); done
```

**The timers run on their own.** All times are UTC:

| Job | When | Writes |
|---|---|---|
| Assessment collector | daily 05:00 | Defender assessments to Cosmos `assessments` |
| Role-assignment collector | daily 05:10 | Role assignments to Cosmos `identities` |
| POA&M | daily 06:00 | `poam-<date>` JSON and XLSX to the WORM `reports` container |
| SAR | Mondays 07:00 | SAR evidence to the `reports` container |
| Drift | nightly 08:00 | A GitHub issue per drifted stage (labelled `drift`) |

Each report is written once per UTC day; a second run that day returns
`{"skipped": true}` instead of failing on the WORM container.

**The evidence answers questions.** After the first 05:10 run:

```bash
~/.venvs/cosmos/bin/python queries/run_privileged_query.py
```

This lists the privileged role assignments in the latest collector run. It ignores
documents left by older runs, because the collector upserts and never deletes.

**The rubric's mechanical checks pass:**

```bash
./self-check.sh
```

## Troubleshooting (all of these happened during this build)

| Symptom | Cause and fix |
|---|---|
| Storage `AuthenticationFailed`, odd `validate` failures in self-check | The machine clock is off (it was 97 minutes slow here). Check `date -u` at the start of each session. |
| `terraform init` 403 `AuthorizationPermissionMismatch` | A new data-plane role is still propagating. Wait 1–3 minutes and retry. |
| A command hangs on `Acquiring state lock` | An interrupted run left a lock. `terraform force-unlock <ID>`, only when nothing else is running. Don't dispatch drift while a gate run is going: both plan the same stages. |
| New functions missing after a deploy | POST `syncfunctiontriggers` (steps 7 and 9). The code was already live. |
| A PR shows no checks at all | GitHub disabled the fork's workflows. Look at the Actions tab first, re-enable, then close and reopen the PR (skipped events are not replayed). |
| Portal Data Explorer: "Authorization header doesn't conform" | The portal uses keys and Cosmos is Entra-only. Query from the terminal with the venv in step 8. |
| `ModuleNotFoundError: No module named 'azure'` from a venv in `/tmp` | macOS cleaned it. Use `~/.venvs/cosmos` as in step 8. |
| `pip install` tries to compile `cryptography` and fails | Add `--only-binary=:all:`. |
| Y1 or F1 quota errors | Free accounts have regional zero quota. Run `./labs/00-setup/probe-quota.sh` and set `TF_VAR_functions_location` or `SEED_APP_LOCATION`. |
| `checkov` fails downloading guidelines | Run it with `--skip-download`. |

## Tear down

Submit first: the grader reads run history from the evidence store. Then run
`./seed-estate.sh --teardown`, and `terraform destroy` each stage in reverse order:
06, 04, 03, 02, 01. Stage 02's destroy returns the Defender plans to Free. The WORM
policy is deliberately unlocked in this sandbox so the container can be removed; a
production deployment would lock it.

Last, remove by hand what was made outside Terraform: the `grc-auditors` group and its
Reader grant, the Activity Log diagnostic setting `ds-activity-to-law`, the budget, the
CI app registration, and `rg-grc-tfstate`.

## Layout

```
stages/     one Terraform root module per pipeline stage, each with its own state (no 05)
functions/  the collectors and report generators (Python, timer-triggered, managed identity)
queries/    stored queries behind numbers in the docs, plus a runner
policy/     OPA/conftest rules that gate this repo's own Terraform, with unit tests
labs/       the six course lab guides and their helper scripts
docs/       setup, architecture, control mappings, rubric, validation log
.github/    the compliance gate (on PRs) and drift detection (nightly)
```

---

*Course starter by the GRC Engineering Club community · www.grcengclub.com*
