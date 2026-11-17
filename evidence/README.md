# Capstone evidence

Raw terminal and report output saved while building the capstone (Nov 4–9, 2026).
Lab evidence stays where the labs put it (`stages/01-foundation/`, `labs/04-evidence/`).

**Redaction:** the shell prompt (user@host) was replaced with `$ `, the home path with `~`,
and the local username with `<operator>`. Nothing else was edited.

| File | Shows | PR |
|---|---|---|
| `seed-run.txt`, `seed-run-2.txt` | Seed estate runs: Deny refuses public blob on `stfafopub421155` (`RequestDisallowedByPolicy`); web app skipped (F1 quota 0) | — (chat 2) |
| `own-policy-compliance.txt` | Own policy `cge-require-secure-transfer`, 00:02 UTC Nov 6 scan: 8 storage accounts, only `stfafopub421155` NonCompliant | #5 |
| `gate-red-pr6.txt` | Own gate rule `policy/transport.rego` failing stages 03 and 04 (Function Apps lacked `https_only`); the next commit fixed them and the gate passed | #6 |
| `identity-collector-evidence.txt` | Role-assignment collector run `7455efa9-…`: 13 documents = 13 from `az role assignment list`; 4 privileged rows; `id-fafo-batch` carries the seed tag | #7 |
| `drift-run-42308227169.txt`, `drift-issue-9.txt` | Drift workflow opening issue #9 for stage 03 | #8 |
| `drift-run-clean-42309358177.txt` | Clean drift run after the fix; issue #9 closed | #10 |
| `checkov-before.txt`, `checkov-after.txt`, `tflint-before.txt` | checkov 34 failed → 0 failed (28 reasoned skips); tflint 10 warnings → 0 | #11 |
| `appinsights-telemetry.txt` | App Insights on both Function Apps, local auth off, 41 trace rows per app | #16 |
| `identities-runs-2026-11-08.txt` | 05:10 UTC Nov 8 run: 15 documents in the run, 1 stale (upsert-only collector) | #13 |
| `poam-2026-11-08-report.txt` | 06:00 UTC Nov 8 POA&M written under the narrower reporter scopes | #13 |
| `privileged-query-before-2026-11-08.txt`, `privileged-query-after-2026-11-08.txt` | Ad-hoc query before/after selecting the latest `runId`: stale document ignored, same 4 privileged rows | — (Nov 8) |
| `poam-owners-cosmos-2026-11-08.txt`, `poam-owners-cosmos-2026-11-08-after.txt` | Unhealthy items with no owner: 32 → 4 | #17, #18 |
| `poam-2026-11-09.json` | Timer POA&M (06:00 UTC Nov 9): 71 items, 67 owned, 4 UNASSIGNED, all on the deliberately untagged `rg-fafo-legacy` | #17, #18 |

The stored query behind the privileged rows is `queries/privileged-role-assignments.sql`.
