locals {
  evidence_rg      = data.terraform_remote_state.foundation.outputs.evidence_resource_group_name
  cosmos_endpoint  = data.terraform_remote_state.evidence.outputs.cosmos_endpoint
  cosmos_id        = data.terraform_remote_state.evidence.outputs.cosmos_account_id
  cosmos_name      = data.terraform_remote_state.evidence.outputs.cosmos_account_name
  evidence_storage = data.terraform_remote_state.evidence.outputs.evidence_storage_account
  common_tags = {
    env     = var.environment
    purpose = "grc-reporting"
  }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

data "azurerm_storage_account" "evidence" {
  name                = local.evidence_storage
  resource_group_name = local.evidence_rg
}

resource "azurerm_storage_account" "func_internal" {
  #checkov:skip=CKV_AZURE_33:queues here are internal to the Functions runtime and hold no evidence
  #checkov:skip=CKV_AZURE_59:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  #checkov:skip=CKV_AZURE_206:LRS in the sandbox; production evidence would use GRS (documented)
  #checkov:skip=CKV2_AZURE_33:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  #checkov:skip=CKV2_AZURE_40:Y1 Functions runtime requires shared-key storage; this account holds no evidence
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys; customer-managed keys need Key Vault and rotation, out of scope for the sandbox (documented)
  name                            = "stgrcrpt${random_string.suffix.result}"
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

resource "azurerm_service_plan" "reporting" {
  #checkov:skip=CKV_AZURE_225:zone redundancy is not available on the Y1 Consumption plan
  #checkov:skip=CKV_AZURE_212:minimum instance count is not available on the Y1 Consumption plan
  name                = "asp-grc-reporting-${var.environment}"
  resource_group_name = local.evidence_rg
  location            = var.functions_location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = local.common_tags
}

# Run logs for the reporting app. Before this, a failed run left no log (Lab 6: a poam_now
# HTTP 500 could only be explained by inference). Workspace-based, so telemetry lands in
# law-grc-sandbox with the rest of the program's logs.
resource "azurerm_application_insights" "reporting" {
  name                = "appi-grc-reporting-${random_string.suffix.result}"
  location            = var.functions_location
  resource_group_name = local.evidence_rg
  workspace_id        = data.terraform_remote_state.foundation.outputs.log_analytics_workspace_id
  application_type    = "web"
  # Entra ID only: the instrumentation key alone cannot send telemetry. The app authenticates
  # with its managed identity (APPLICATIONINSIGHTS_AUTHENTICATION_STRING below).
  local_authentication_enabled = false
  tags                         = local.common_tags
}

resource "azurerm_linux_function_app" "reporting" {
  #checkov:skip=CKV_AZURE_221:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  lifecycle {
    # config-zip deploys remove this setting; not a real change.
    ignore_changes = [app_settings["ENABLE_ORYX_BUILD"]]
  }

  https_only = true # gate rule policy/transport.rego (PR.DS-02)
  # No username/password publishing (FTP or SCM/Kudu): deploys authenticate with Entra ID.
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  name                                           = "func-grc-reporting-${random_string.suffix.result}"
  resource_group_name                            = local.evidence_rg
  location                                       = var.functions_location
  service_plan_id                                = azurerm_service_plan.reporting.id
  storage_account_name                           = azurerm_storage_account.func_internal.name
  storage_account_access_key                     = azurerm_storage_account.func_internal.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    # Writes APPLICATIONINSIGHTS_CONNECTION_STRING; the value stays sensitive in state and plans.
    application_insights_connection_string = azurerm_application_insights.reporting.connection_string
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    "COSMOS_ENDPOINT"                           = local.cosmos_endpoint
    "COSMOS_DATABASE"                           = "grc"
    "REPORTS_ACCOUNT_URL"                       = data.azurerm_storage_account.evidence.primary_blob_endpoint
    "REPORTS_CONTAINER"                         = "reports"
    "APPLICATIONINSIGHTS_AUTHENTICATION_STRING" = "Authorization=AAD"
    "SCM_DO_BUILD_DURING_DEPLOYMENT"            = "true"
    "ENABLE_ORYX_BUILD"                         = "true"
  }

  tags = local.common_tags
}

# --- The reporting identity's whitelist — the mirror image of the collector's. ---
# Cosmos READ (built-in Data Reader), Blob WRITE into the WORM container. No path to
# live platform data: no Security Reader, no Cosmos write. SoD, enforced by scopes.

resource "azurerm_cosmosdb_sql_role_assignment" "reporter_cosmos_read" {
  resource_group_name = local.evidence_rg
  account_name        = local.cosmos_name
  role_definition_id  = "${local.cosmos_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001"
  principal_id        = azurerm_linux_function_app.reporting.identity[0].principal_id
  # Only the container the reporter reads (function_app.py), not the whole account.
  scope = "${local.cosmos_id}/dbs/grc/colls/assessments"
}

resource "azurerm_role_assignment" "reporter_blob_write" {
  # Only the WORM reports container, not every container in the evidence account.
  scope                = "${data.azurerm_storage_account.evidence.id}/blobServices/default/containers/reports"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_function_app.reporting.identity[0].principal_id
}

# Telemetry with the app's own identity: publish to its own App Insights, nothing else.
resource "azurerm_role_assignment" "reporter_appinsights_publish" {
  scope                = azurerm_application_insights.reporting.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_linux_function_app.reporting.identity[0].principal_id
}

output "reporting_function_app" {
  value = azurerm_linux_function_app.reporting.name
}

output "reporter_principal_id" {
  value = azurerm_linux_function_app.reporting.identity[0].principal_id
}
