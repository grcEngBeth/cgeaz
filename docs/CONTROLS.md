# Control Mappings

Every policy, collector, gate rule and pipeline setting in this repo, mapped to the
NIST CSF 2.0 categories it serves. Each row says what the control does as built
(not as the starter shipped it); where a control falls short, the gap is named here
or in ARCHITECTURE.md section 3 rather than left out.

Framework: NIST CSF 2.0 only. Categories are cited (for example `PR.DS`); a
subcategory is added where one control maps to it specifically.

## Policy sources on the subscription

Three sources report Azure Policy compliance. Only the first is managed by this
repo's enforcement code; the second is assigned by this repo but only reports;
the third is Defender's own.

| Assignment | Scope | Mode | Managed by | Role in the pipeline |
|---|---|---|---|---|
| `cge-grc-baseline` (initiative) | `mg-grc-sandbox` | Default | Stage 01 | The controls in the next section |
| Remediation assignment (`cge-fix-public-blob`) | `mg-grc-sandbox` | DoNotEnforce (dry-run) | Stage 06 | Flags; fixes only through a human-created remediation task |
| `nist-csf-20` (NIST CSF v2.0 built-in) | Subscription | Default | Stage 02 | Reports in Policy; not collected into Cosmos |
| `SecurityCenterBuiltIn` (ASC Default / Microsoft cloud security benchmark) | Subscription | Default | Defender for Cloud | Source of the Defender assessments the collector reads |

## Stage 01 — Foundation

| Component | What it does | CSF 2.0 |
|---|---|---|
| Management group hierarchy (`mg-grc`, `mg-grc-sandbox`) + baseline assignment | Controls inherit to every current and future subscription under `mg-grc-sandbox` | GV.PO, GV.OC |
| `cge-require-env-tag-rg` (Audit) | Flags resource groups without an `env` tag (inventory hygiene); `rg-fafo-legacy` is the deliberate failing sample. Effect: `var.tag_policy_effect` | ID.AM |
| `cge-deny-public-blob` (Deny) | Refuses any storage account create or update that allows public blob access, at the API, before the resource exists. Effect: `var.public_blob_policy_effect` (default Deny). Proved: `stfafopub421155` refused with `RequestDisallowedByPolicy` | PR.DS (PR.DS-01) |
| `cge-require-secure-transfer` (Audit, own policy) | Flags storage accounts with `supportsHttpsTrafficOnly` false; effect set by `var.secure_transfer_policy_effect`. 7 of 8 accounts Compliant, only `stfafopub421155` NonCompliant, matching Defender (PR #5) | PR.DS (PR.DS-02) |
| `cge-dine-storage-diagnostics` (DeployIfNotExists) | Writes an account-level diagnostic setting (Transaction and Capacity metrics) to `law-grc-sandbox` on storage accounts that lack one, through the remediation identity. Proved on `stfafologs421155` (deployed 23:44 UTC Nov 4, then Compliant) | PR.PS (PR.PS-04), DE.CM |
| Remediation identity (user-assigned) | Monitoring Contributor at `mg-grc-sandbox`; the storage-write grant is stage 06's (below). Every automated change has one named, auditable author, recorded in the Activity Log by principal ID | PR.AA, GV.RR |
| Log Analytics workspace `law-grc-sandbox` + Activity Log routing | Central audit trail beyond the 90-day Activity Log default | DE.CM, PR.PS |
| `grc-auditors` Entra group, Reader on `rg-grc-sandbox-dev` | Auditors can read the lab resource group and change nothing. Created by hand in Lab 1 (`labs/01-sandbox/README.md`), not by Terraform, so drift does not watch it and a rebuild must recreate it | PR.AA, GV.OV |
| Terraform state storage (`rg-grc-tfstate`, created by `labs/03-foundation/bootstrap.sh`) | TLS 1.2 minimum, public blob access off, blob versioning on (every state change is a recoverable version); group and account tagged with `owner`. CI writes state through Storage Blob Data Contributor on `rg-grc-tfstate` only | PR.DS (PR.DS-11), PR.PS |

## Stage 02 — Activation

| Component | What it does | CSF 2.0 |
|---|---|---|
| Defender for Cloud plans | Turns on the continuous assessments the collector reads | DE.CM, ID.RA |
| `nist-csf-20` assignment | Built-in CSF 2.0 initiative at the subscription; reports in Policy, so policy-only findings (env tag, NSG 22/3389) live there, not in Cosmos | GV.OV, ID.RA |
| Stage in the gate, drift and guide-ci matrices (PR #11) | Plan tiers and the CSF assignment are now gated and watched for drift; before PR #11 no workflow planned this stage | PR.PS, DE.CM |

## Stage 03 — Evidence store and collectors

| Component | What it does | CSF 2.0 |
|---|---|---|
| Cosmos DB `grc` (assessments, identities, frameworks, mappings) | Owned evidence schema; collect once, map to any framework. Reports read only the latest `runId`, so stale documents never reach a report | GV.OV, ID.RA |
| WORM immutability policy on `reports` | Report blobs cannot be overwritten or deleted while the policy holds (`BlobImmutableDueToPolicy`). Unlocked in the sandbox so it can be torn down | PR.DS (PR.DS-01) |
| Identity-only data access | No shared keys on evidence storage, local auth off on Cosmos, Cosmos key-metadata writes off | PR.AA |
| Assessment collector (daily 05:00 UTC) | Reads every Defender assessment subscription-wide with Security Reader and `$expand=metadata` (severity), stamps each with resource group and owner tag; writes only to `assessments` | DE.CM, ID.RA, GV.RR |
| Role-assignment collector (daily 05:10 UTC, own query) | One document per role assignment with a `privileged` flag, in `identities`; write grant scoped to that container, no new ARM role. Stored query: `queries/privileged-role-assignments.sql` (latest run only) | PR.AA, DE.CM |
| Collector / reporter / human separation | Collector writes evidence and reads nothing it reports; reporter reads `assessments` only and writes the `reports` container only; humans read Cosmos and write only reference data (`frameworks`, `mappings`). The recorder of facts cannot author the narrative, and no human can write evidence (PR #13) | PR.AA (PR.AA-05), GV.RR |
| `SUBSCRIPTION_OWNER` | Subscription-level findings get a named owner without granting the collector subscription read (PR #18) | GV.RR |
| Function Apps: HTTPS only, TLS 1.2, basic-auth publishing off | Code can be published only with Entra ID; no username/password path (PRs #6, #14) | PR.DS (PR.DS-02), PR.AA |
| Application Insights, local auth off | Each app sends telemetry with its managed identity (Monitoring Metrics Publisher on its own App Insights only); a failed run now leaves a log (PR #16) | PR.PS (PR.PS-04), DE.CM |

## Stage 04 — Reporting

| Component | What it does | CSF 2.0 |
|---|---|---|
| POA&M generator (daily 06:00 UTC, SLA-dated) | Every unhealthy finding from the latest run with an owner or UNASSIGNED; skips instead of failing when today's WORM file exists (PR #2). Nov 9: 71 items, 67 owned | ID.IM, GV.RM |
| SAR generator (Mondays 07:00 UTC) | Assessment summary where every number traces to a stored document. The real SAR belongs to the independent assessor; this is its evidence | ID.RA, GV.OV |

Stage 05 (digest) is not built.

## Stage 06 — Enforcement

| Component | What it does | CSF 2.0 |
|---|---|---|
| `cge-fix-public-blob` (Modify) | Sets `allowBlobPublicAccess` to false through the remediation identity. Runs in dry-run: flags, fixes only when a human creates a remediation task. Proved in Lab 6: task `Succeeded`, Activity Log author `0c061249-…` | PR.DS, RS.MI |
| `cge-remediation-storage-writer` (custom role) | Storage account read/write and resource group read only, replacing Storage Account Contributor (which also allowed delete and `listKeys`). Granted only when the mode is enforcing (count 0 in dry-run) (PR #3) | PR.AA (PR.AA-05) |
| `remediation_mode` variable | Escalation is a reviewed diff: automation acts, humans authorize | GV.PO, GV.RR |

## Blast radius of every enforcement policy

What each policy touches when it acts, what breaks if it is wrong, and how it is turned down. Every change to an effect is a PR through the gate.

| Policy | Effect and scope | When it acts | If it is wrong | Turn it down |
|---|---|---|---|---|
| `cge-deny-public-blob` | Deny, every subscription under `mg-grc-sandbox` | Refuses the create or update; nothing already running changes | Any deployment that needs anonymous blob reads (a static site, public downloads) fails at the API. None of the pipeline's own accounts allow public access | `var.public_blob_policy_effect` (Audit or Disabled) |
| `cge-dine-storage-diagnostics` | DeployIfNotExists, storage accounts under `mg-grc-sandbox` | Adds a diagnostic setting (metrics only) to an account that lacks one, about 3.5 hours after creation | Writes to every storage account in scope; adds Log Analytics ingestion cost; does not touch data, keys or network rules | PR to stage 01 (effect is fixed in the definition, no variable) |
| `cge-require-secure-transfer` | Audit, storage accounts under `mg-grc-sandbox` | Reports only | Nothing breaks. At Deny, HTTP-only accounts could not be created or updated; today only `stfafopub421155` (seed) would be affected, none of the pipeline's | `var.secure_transfer_policy_effect` |
| `cge-require-env-tag-rg` | Audit, resource groups under `mg-grc-sandbox` | Reports only | Nothing breaks. At Deny, untagged groups (including Azure-created ones such as `NetworkWatcherRG`) could not be created | `var.tag_policy_effect` |
| `cge-fix-public-blob` | Modify, `mg-grc-sandbox`, DoNotEnforce | Nothing until a human creates a remediation task | When enforcing, flips public access off on existing accounts: anything serving anonymous blobs stops working. The identity can change account settings but cannot delete accounts or read keys | `remediation_mode` (back to dry-run also removes the storage grant) |

Defender for Cloud re-assesses on its own schedule, so a finding fixed by remediation can stay in the POA&M until the next assessment.

## Repo gates (policy/ and workflows)

| Rule | Mistake it makes unmergeable, or catches | CSF 2.0 |
|---|---|---|
| `storage.rego` | Pipeline storage below the pipeline's own standard | PR.DS |
| `transport.rego` (own gate rule) | Storage accounts or Function Apps without HTTPS-only and TLS 1.2+. Proved on PR #6: red on stages 03 and 04, green after the fix | PR.DS (PR.DS-02) |
| `policy_identity.rego` | Remediation that silently never runs | PR.PS |
| `broad_roles.rego` + 13 unit tests | Owner, Contributor, User Access Administrator or RBAC Administrator grants, by name or by role ID (PR #12) | PR.AA (PR.AA-05) |
| Gate workflow: five stages, required checks, bypass off, conftest pinned by digest | No change reaches `main` without a passing plan and policy check; the gate cannot change under the repo | PR.PS (PR.PS-01), GV.SC |
| `drift.yml` + KQL tripwire | Out-of-band change: one open issue per drifting stage (proved: issue #9); the tripwire filters the Activity Log by the remediation identity's principal ID | DE.CM, DE.AE |
| checkov, tflint, gitleaks (`self-check.sh`, run locally) | Misconfiguration and committed secrets; every skip has an inline reason. Not yet in CI | PR.PS, PR.DS |

Branch protection holds only as long as "Do not allow bypassing" stays on, and GitHub can disable workflows on a fork without notice (Nov 2026: no gate ran for about a week; nothing merged ungated because the checks were required).
