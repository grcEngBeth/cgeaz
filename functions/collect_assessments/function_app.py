"""CGE-AZ pipeline — Stage 3 collector.

Timer fires nightly -> managed identity -> Defender assessments API -> Cosmos.
One document per assessment per run, upserted on a deterministic ID so re-runs
refresh instead of duplicate. Deliberately boring: if you can read this file,
you can defend this pipeline's data lineage.
"""

import datetime
import hashlib
import logging
import os
import uuid

import azure.functions as func
import requests
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()

ARM = "https://management.azure.com"
API_VERSION = "2021-06-01"
RG_API_VERSION = "2021-04-01"


def _resource_group(resource_id: str):
    """Lowercased resource group name from an ARM ID, or None for subscription-level
    findings. Defender returns lowercase paths, so both sides of the lookup are lowercase."""
    parts = resource_id.strip("/").split("/")
    for i, part in enumerate(parts[:-1]):
        if part.lower() == "resourcegroups":
            return parts[i + 1].lower()
    return None


def _collect() -> dict:
    subscription_id = os.environ["SUBSCRIPTION_ID"]
    cosmos_endpoint = os.environ["COSMOS_ENDPOINT"]
    database = os.environ["COSMOS_DATABASE"]

    # DefaultAzureCredential resolves to the Function App's managed identity in Azure
    # (and to your `az login` session when run locally). No keys, anywhere.
    credential = DefaultAzureCredential()
    token = credential.get_token(f"{ARM}/.default").token

    run_id = str(uuid.uuid4())
    collected_at = datetime.datetime.now(datetime.timezone.utc).isoformat()

    container = (
        CosmosClient(cosmos_endpoint, credential)
        .get_database_client(database)
        .get_container_client("assessments")
    )

    # POA&M owners (capstone): each finding carries its resource group's `owner` tag,
    # read once per run. Needs Microsoft.Resources/subscriptions/resourceGroups/read,
    # which Security Reader grants. Tag keys are case-insensitive in Azure.
    # A failed lookup must not cost a night of evidence: log it, leave owners null,
    # and the POA&M shows those items as unassigned.
    owners = {}
    try:
        for rg in _arm_list(
            f"{ARM}/subscriptions/{subscription_id}/resourcegroups?api-version={RG_API_VERSION}", token
        ):
            tags = {k.lower(): v for k, v in (rg.get("tags") or {}).items()}
            owners[rg["name"].lower()] = tags.get("owner")
    except requests.RequestException:
        logging.error("owner lookup failed: resource group tags not read; owners left null")
    logging.info("owner lookup: %d resource groups, %d with an owner tag",
                 len(owners), sum(1 for o in owners.values() if o))

    url = (
        f"{ARM}/subscriptions/{subscription_id}"
        f"/providers/Microsoft.Security/assessments?api-version={API_VERSION}"
        # $expand=metadata: without it the list API omits severity/categories and every
        # document lands with severity null (found tracing ad4f3ff1 in Lab 4).
        "&$expand=metadata"
    )
    written = 0
    while url:
        resp = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=60)
        resp.raise_for_status()
        payload = resp.json()

        for assessment in payload.get("value", []):
            props = assessment.get("properties", {})
            resource_id = (
                props.get("resourceDetails", {}).get("Id")
                or props.get("resourceDetails", {}).get("id", "")
            )
            rg_name = _resource_group(resource_id)
            # Deterministic ID: same assessment+resource upserts, never duplicates.
            doc_id = hashlib.sha256(
                f"{assessment['name']}|{resource_id}".encode()
            ).hexdigest()[:32]

            container.upsert_item(
                {
                    "id": doc_id,
                    "subscriptionId": subscription_id,
                    "assessmentId": assessment["name"],
                    "displayName": props.get("displayName"),
                    "status": props.get("status", {}).get("code"),
                    "statusCause": props.get("status", {}).get("cause"),
                    "severity": props.get("metadata", {}).get("severity"),
                    "categories": props.get("metadata", {}).get("categories"),
                    "resourceId": resource_id,
                    "resourceGroup": rg_name,
                    "owner": owners.get(rg_name) if rg_name else None,
                    "collectedAt": collected_at,
                    "runId": run_id,
                }
            )
            written += 1

        url = payload.get("nextLink")

    logging.info("collection run %s complete: %d documents", run_id, written)
    return {"runId": run_id, "written": written, "collectedAt": collected_at}


@app.timer_trigger(schedule="0 0 5 * * *", arg_name="timer", run_on_startup=False)
def collect_nightly(timer: func.TimerRequest) -> None:
    """Nightly sweep at 05:00 UTC — midnight-ish US Eastern."""
    _collect()


@app.route(route="collect", auth_level=func.AuthLevel.FUNCTION)
def collect_now(req: func.HttpRequest) -> func.HttpResponse:
    """Manual trigger for labs and demos: hit the endpoint, get the run summary."""
    result = _collect()
    return func.HttpResponse(
        f"run {result['runId']}: {result['written']} documents at {result['collectedAt']}\n",
        status_code=200,
    )


# --- Role-assignment collector (capstone) ---------------------------------------------
# Same identity, same pattern: ARM list -> deterministic-ID upsert -> Cosmos `identities`.
# Reads need only Microsoft.Authorization/*/read, which Security Reader already grants.
# Principal display names would need directory (Graph) read; deliberately not granted,
# so documents carry principal IDs and types only.

AUTHZ_API_VERSION = "2022-04-01"

# Roles that can change resources or grant access. Flagged so a stored query can list them.
PRIVILEGED_ROLES = {
    "Owner",
    "Contributor",
    "User Access Administrator",
    "Role Based Access Control Administrator",
}


def _arm_list(url: str, token: str) -> list:
    """GET an ARM list endpoint and follow nextLink to the end."""
    items = []
    while url:
        resp = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=60)
        resp.raise_for_status()
        payload = resp.json()
        items.extend(payload.get("value", []))
        url = payload.get("nextLink")
    return items


def _scope_level(scope: str) -> str:
    s = scope.lower()
    if s.startswith("/providers/microsoft.management/managementgroups/"):
        return "managementGroup"
    if s == "/":
        return "root"
    parts = s.strip("/").split("/")
    if len(parts) == 2:
        return "subscription"
    if len(parts) == 4 and parts[2] == "resourcegroups":
        return "resourceGroup"
    return "resource"


def _collect_identities() -> dict:
    subscription_id = os.environ["SUBSCRIPTION_ID"]
    credential = DefaultAzureCredential()
    token = credential.get_token(f"{ARM}/.default").token
    headers = {"Authorization": f"Bearer {token}"}

    run_id = str(uuid.uuid4())
    collected_at = datetime.datetime.now(datetime.timezone.utc).isoformat()

    container = (
        CosmosClient(os.environ["COSMOS_ENDPOINT"], credential)
        .get_database_client(os.environ["COSMOS_DATABASE"])
        .get_container_client("identities")
    )

    base = f"{ARM}/subscriptions/{subscription_id}/providers/Microsoft.Authorization"
    # Role names keyed by definition GUID: subscription- and management-group-scoped IDs
    # differ in prefix, but the GUID is the same.
    role_names = {
        d["name"].lower(): d.get("properties", {}).get("roleName")
        for d in _arm_list(f"{base}/roleDefinitions?api-version={AUTHZ_API_VERSION}", token)
    }

    # No $filter: returns assignments at, above (inherited from management groups) and
    # below (resource groups, resources) this subscription.
    assignments = _arm_list(f"{base}/roleAssignments?api-version={AUTHZ_API_VERSION}", token)

    written = 0
    for ra in assignments:
        props = ra.get("properties", {})
        role_def_id = props.get("roleDefinitionId", "")
        guid = role_def_id.rsplit("/", 1)[-1].lower()
        if guid and guid not in role_names:
            # A custom role defined at a management group can be missing from the
            # subscription list; look it up once by ID. Failure leaves roleName null
            # (the ID is still recorded) rather than failing the whole run.
            try:
                r = requests.get(f"{ARM}{role_def_id}?api-version={AUTHZ_API_VERSION}", headers=headers, timeout=60)
                r.raise_for_status()
                role_names[guid] = r.json().get("properties", {}).get("roleName")
            except requests.RequestException:
                logging.warning("could not resolve role definition %s", role_def_id)
                role_names[guid] = None
        role_name = role_names.get(guid)
        scope = props.get("scope", "")

        container.upsert_item(
            {
                # Deterministic ID from the assignment's own ARM ID: re-runs refresh, never duplicate.
                "id": hashlib.sha256(ra["id"].lower().encode()).hexdigest()[:32],
                "docType": "roleAssignment",
                "subscriptionId": subscription_id,
                "roleAssignmentId": ra["id"],
                "principalId": props.get("principalId"),
                "principalType": props.get("principalType"),
                "roleDefinitionId": role_def_id,
                "roleName": role_name,
                "privileged": role_name in PRIVILEGED_ROLES,
                "scope": scope,
                "scopeLevel": _scope_level(scope),
                "createdOn": props.get("createdOn"),
                "collectedAt": collected_at,
                "runId": run_id,
            }
        )
        written += 1

    logging.info("identity collection run %s complete: %d documents", run_id, written)
    return {"runId": run_id, "written": written, "collectedAt": collected_at}


@app.timer_trigger(schedule="0 10 5 * * *", arg_name="timer", run_on_startup=False)
def collect_identities_nightly(timer: func.TimerRequest) -> None:
    """Nightly at 05:10 UTC: after the assessments sweep, before the 06:00 POA&M."""
    _collect_identities()


@app.route(route="collect-identities", auth_level=func.AuthLevel.FUNCTION)
def collect_identities_now(req: func.HttpRequest) -> func.HttpResponse:
    """Manual trigger for demos: same as the timer, returns the run summary."""
    result = _collect_identities()
    return func.HttpResponse(
        f"run {result['runId']}: {result['written']} role assignments at {result['collectedAt']}\n",
        status_code=200,
    )
