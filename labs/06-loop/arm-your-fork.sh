#!/usr/bin/env bash
# Arm YOUR fork's CI workflows against YOUR sandbox subscription.
#
# Creates an OIDC app registration federated to your fork, grants it the roles the
# plan-only workflows need, and prints the five repository VARIABLES to add in your
# fork's UI: Settings -> Secrets and variables -> Actions -> Variables tab.
#
# Why variables and not secrets? With OIDC there is no credential to protect —
# client/tenant/subscription IDs are identifiers, and possessing them grants nothing
# without a matching federation subject. The security boundary is the federation:
# it names YOUR fork, so only workflows running in YOUR fork can exchange tokens.
#
# Why never arm the upstream repo? On a public repo, the pull_request OIDC subject
# matches PRs from ANY fork, and pull_request runs the workflow file AS MODIFIED BY
# THE PR. Arming a public upstream hands every fork PR a path toward the subscription
# behind it. Your fork is low-traffic and yours; the course subscription is neither.
# (This reasoning is exam-relevant. You just read a trust-boundary analysis.)
set -euo pipefail

GH_USER="${1:?usage: ./arm-your-fork.sh <your-github-username-or-org>}"
REPO="${2:-cgeaz}"
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo ">> App registration: github-${REPO}-${GH_USER}"
APP_NAME="github-${REPO}-${GH_USER}"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [[ -z "$APP_ID" ]]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
else
  echo "   (app registration already exists: $APP_ID)"
fi
APP_OBJ=$(az ad app show --id "$APP_ID" --query id -o tsv)
if ! az ad sp show --id "$APP_ID" --output none 2>/dev/null; then
  az ad sp create --id "$APP_ID" --output none
fi
SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

echo ">> Federated credentials for repo:${GH_USER}/${REPO} (pull_request + main, name and numeric-ID subjects)"
# This fork's tokens carry the numeric-ID subject (repo:owner@OWNER_ID/repo@REPO_ID:...).
# With only the name-based rules, login failed with AADSTS700213 in Lab 6.
# Create both forms so a rebuild from an empty subscription needs no manual steps.
OWNER_ID=$(gh api "users/${GH_USER}" --jq .id)
REPO_ID=$(gh api "repos/${GH_USER}/${REPO}" --jq .id)
for sub in \
  "repo:${GH_USER}/${REPO}:pull_request|pr" \
  "repo:${GH_USER}/${REPO}:ref:refs/heads/main|main" \
  "repo:${GH_USER}@${OWNER_ID}/${REPO}@${REPO_ID}:pull_request|pr-id" \
  "repo:${GH_USER}@${OWNER_ID}/${REPO}@${REPO_ID}:ref:refs/heads/main|main-id"; do
  SUBJECT="${sub%|*}"; NAME="${sub#*|}"
  EXISTING=$(az ad app federated-credential list --id "$APP_OBJ" --query "[?subject=='${SUBJECT}'] | length(@)" -o tsv)
  if [[ "$EXISTING" != "0" ]]; then
    echo "   (already federated: ${SUBJECT})"
    continue
  fi
  az ad app federated-credential create --id "$APP_OBJ" --parameters "{
    \"name\": \"${REPO}-${NAME}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none
done

MG_SCOPE="/providers/Microsoft.Management/managementGroups/mg-grc"
ROLE_FILE="$(dirname "$0")/ci-planner-role.json"

echo ">> Custom role cge-ci-planner: */read + the list actions plan/refresh needs; no writes, no RBAC"
if [[ "$(az role definition list --name cge-ci-planner --custom-role-only true --scope "$MG_SCOPE" --query 'length(@)' -o tsv)" == "0" ]]; then
  az role definition create --role-definition "$ROLE_FILE" --output none
else
  echo "   (role definition already exists)"
fi

# Assign once. Skip if already assigned; retry while a new role or principal
# propagates; fail loudly on anything else.
assign_role() {
  local role="$1" scope="$2" tries=0
  if [[ "$(az role assignment list --assignee "$SP_ID" --role "$role" --scope "$scope" --query 'length(@)' -o tsv)" != "0" ]]; then
    echo "   ($role already assigned at $scope)"; return
  fi
  until az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" --output none; do
    tries=$((tries+1))
    if (( tries >= 6 )); then echo "!! could not assign $role at $scope" >&2; exit 1; fi
    echo "   (waiting for propagation, retry $tries/5)"; sleep 20
  done
}

echo ">> Roles: cge-ci-planner at mg-grc + blob data on the state RG"
assign_role "cge-ci-planner" "$MG_SCOPE"
assign_role "Storage Blob Data Contributor" "/subscriptions/$SUB_ID/resourceGroups/rg-grc-tfstate"

STATE_SA=$(grep storage_account_name "$(dirname "$0")/../03-foundation/backend.hcl" 2>/dev/null | tr -d ' "' | cut -d= -f2 || echo "<from backend.hcl>")

cat <<EOF

Done. Add these five VARIABLES (not secrets — see header comment) in YOUR fork:
Settings -> Secrets and variables -> Actions -> Variables -> New repository variable

  AZURE_CLIENT_ID        $APP_ID
  AZURE_TENANT_ID        $TENANT_ID
  AZURE_SUBSCRIPTION_ID  $SUB_ID
  STATE_STORAGE_ACCOUNT  $STATE_SA
  OWNER_EMAIL            grc-sandbox-owner@example.com   (role placeholder; keep personal email out of tags)

Then enable the two workflows in your fork's Actions tab. Never add these to the
upstream GRCEngClub/cgeaz repo — its workflows are intentionally unarmed.
EOF
