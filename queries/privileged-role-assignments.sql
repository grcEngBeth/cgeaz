-- Privileged role assignments in the latest role-assignment collector run.
-- Source: Cosmos database grc, container identities (partition /subscriptionId),
-- written nightly at 05:10 UTC by the identities collector.
-- @runId is the runId with the newest collectedAt. The collector upserts and never
-- deletes, so a removed assignment keeps its document under an older runId;
-- filtering on the latest run ignores those stale documents.
-- Run it with: python queries/run_privileged_query.py (needs COSMOS_ENDPOINT).
SELECT c.roleName, c.principalType, c.principalId, c.scopeLevel, c.scope, c.runId, c.collectedAt
FROM c
WHERE c.docType = 'roleAssignment' AND c.privileged = true AND c.runId = @runId
ORDER BY c.roleName
