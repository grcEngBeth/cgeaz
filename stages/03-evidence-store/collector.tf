# --- The collector Function App: timer-triggered Python, managed identity, zero keys. ---
# One app for collectors, a separate app (stage 04) for reporting: the Function App is
# the identity boundary, and no identity both writes evidence and generates reports.

# Internal plumbing storage for the Functions runtime (NOT the evidence store —
# that account has shared keys disabled; this one is the app's own scratch space).
resource "azurerm_storage_account" "func_internal" {
  #checkov:skip=CKV_AZURE_33:queues here are internal to the Functions runtime and hold no evidence
  #checkov:skip=CKV_AZURE_59:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  #checkov:skip=CKV_AZURE_206:LRS in the sandbox; production evidence would use GRS (documented)
  #checkov:skip=CKV2_AZURE_33:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  #checkov:skip=CKV2_AZURE_40:Y1 Functions runtime requires shared-key storage; this account holds no evidence
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys; customer-managed keys need Key Vault and rotation, out of scope for the sandbox (documented)
  name                            = "stgrcfunc${random_string.suffix.result}"
  resource_group_name             = local.evidence_rg
  location                        = var.functions_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # The Y1 Functions runtime connects with the account key (see the CKV2_AZURE_40 skip).
  shared_access_key_enabled = true

  sas_policy {
    expiration_period = "01.00:00:00"
    expiration_action = "Log"
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.common_tags
}

resource "azurerm_service_plan" "collectors" {
  #checkov:skip=CKV_AZURE_225:zone redundancy is not available on the Y1 Consumption plan
  #checkov:skip=CKV_AZURE_212:minimum instance count is not available on the Y1 Consumption plan
  name                = "asp-grc-collectors-${var.environment}"
  resource_group_name = local.evidence_rg
  location            = var.functions_location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption: pay per execution. Pennies.
  tags                = local.common_tags
}

resource "azurerm_linux_function_app" "collectors" {
  #checkov:skip=CKV_AZURE_221:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  lifecycle {
    # config-zip deploys remove this setting; not a real change.
    ignore_changes = [app_settings["ENABLE_ORYX_BUILD"]]
  }

  https_only = true # gate rule policy/transport.rego (PR.DS-02)
  # No username/password publishing (FTP or SCM/Kudu): deploys authenticate with Entra ID.
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  name                                           = "func-grc-collectors-${random_string.suffix.result}"
  resource_group_name                            = local.evidence_rg
  location                                       = var.functions_location
  service_plan_id                                = azurerm_service_plan.collectors.id
  storage_account_name                           = azurerm_storage_account.func_internal.name
  storage_account_access_key                     = azurerm_storage_account.func_internal.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    "COSMOS_ENDPOINT"                = azurerm_cosmosdb_account.evidence.endpoint
    "COSMOS_DATABASE"                = azurerm_cosmosdb_sql_database.grc.name
    "SUBSCRIPTION_ID"                = local.subscription
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "ENABLE_ORYX_BUILD"              = "true"
  }

  tags = local.common_tags
}

# --- The collector identity's whitelist: read posture, write evidence. Nothing else. ---

# Security Reader at the subscription: read Defender assessments, change nothing.
resource "azurerm_role_assignment" "collector_security_reader" {
  scope                = "/subscriptions/${local.subscription}"
  role_definition_name = "Security Reader"
  principal_id         = azurerm_linux_function_app.collectors.identity[0].principal_id
}

# Cosmos data-plane write for the collector identity.
# Role: "Cosmos DB Built-in Data Contributor" (00000000-0000-0000-0000-000000000002), a
# Cosmos-native data-plane role, not an ARM role — control plane vs data plane, again.
#
# Scope: deliberately narrowed from the account (reference build) to the `assessments`
# container. The collector writes nothing else — function_app.py calls only
# get_container_client("assessments") and ("identities"), each with its own grant below —
# so it has no business in `frameworks` or `mappings`.
# Account scope would let the identity that produces findings also rewrite the crosswalk
# that decides which controls those findings satisfy. Separation of duties, enforced by
# role scope rather than by convention.
resource "azurerm_cosmosdb_sql_role_assignment" "collector_cosmos_write" {
  resource_group_name = local.evidence_rg
  account_name        = azurerm_cosmosdb_account.evidence.name
  role_definition_id  = "${azurerm_cosmosdb_account.evidence.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_linux_function_app.collectors.identity[0].principal_id
  scope               = "${azurerm_cosmosdb_account.evidence.id}/dbs/${azurerm_cosmosdb_sql_database.grc.name}/colls/${azurerm_cosmosdb_sql_container.assessments.name}"
}

# Same pattern for the role-assignment collector (capstone): write to `identities` only.
# Reading role assignments needs no new ARM role: Security Reader above already grants
# Microsoft.Authorization/*/read (checked with az role definition list, Nov 6 2026).
resource "azurerm_cosmosdb_sql_role_assignment" "collector_cosmos_write_identities" {
  resource_group_name = local.evidence_rg
  account_name        = azurerm_cosmosdb_account.evidence.name
  role_definition_id  = "${azurerm_cosmosdb_account.evidence.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_linux_function_app.collectors.identity[0].principal_id
  scope               = "${azurerm_cosmosdb_account.evidence.id}/dbs/${azurerm_cosmosdb_sql_database.grc.name}/colls/${azurerm_cosmosdb_sql_container.identities.name}"
}
