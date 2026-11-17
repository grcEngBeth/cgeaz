"""Run queries/privileged-role-assignments.sql against the latest identities run.

Needs: pip install azure-cosmos azure-identity, az login, and
COSMOS_ENDPOINT (az cosmosdb list --query '[0].documentEndpoint' -o tsv).
Reads with your Entra identity (Cosmos Data Reader); no keys.
"""
import os
import sys
from collections import Counter
from pathlib import Path

from azure.cosmos import CosmosClient
from azure.identity import AzureCliCredential

SQL_FILE = Path(__file__).with_name("privileged-role-assignments.sql")


def load_query():
    lines = SQL_FILE.read_text().splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("--"))


def main():
    endpoint = os.environ.get("COSMOS_ENDPOINT")
    if not endpoint:
        sys.exit("Set COSMOS_ENDPOINT first (see the docstring).")
    container = (CosmosClient(endpoint, AzureCliCredential())
                 .get_database_client("grc").get_container_client("identities"))

    all_docs = list(container.query_items(
        "SELECT c.runId, c.collectedAt FROM c WHERE c.docType = 'roleAssignment'",
        enable_cross_partition_query=True))
    if not all_docs:
        sys.exit("No roleAssignment documents in identities.")
    per_run = Counter(d["runId"] for d in all_docs)
    run_time = {}
    for d in all_docs:
        run_time[d["runId"]] = max(run_time.get(d["runId"], ""), d["collectedAt"])
    latest = max(run_time, key=run_time.get)

    print(f"roleAssignment documents in identities: {len(all_docs)}")
    print(f"latest run: {latest} at {run_time[latest][:16]} UTC, {per_run[latest]} documents")
    print(f"stale documents from older runs (ignored): {len(all_docs) - per_run[latest]}")

    rows = list(container.query_items(
        load_query(), parameters=[{"name": "@runId", "value": latest}],
        enable_cross_partition_query=True))
    print(f"privileged assignments in latest run: {len(rows)}")
    for r in rows:
        print(f"- {r['roleName']} | {r['principalType']} | {r['principalId']} | "
              f"{r['scopeLevel']} | {r['scope']}")


if __name__ == "__main__":
    main()
