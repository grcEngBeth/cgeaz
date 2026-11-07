locals {
  evidence_rg  = data.terraform_remote_state.foundation.outputs.evidence_resource_group_name
  subscription = data.terraform_remote_state.foundation.outputs.subscription_id
  common_tags = {
    env     = var.environment
    purpose = "grc-evidence-plane"
  }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# --- Cosmos DB: the evidence database we OWN. Serverless; pennies at lab scale. ---

resource "azurerm_cosmosdb_account" "evidence" {
  #checkov:skip=CKV_AZURE_140:local auth is off via local_authentication_enabled = false; checkov reads only the deprecated attribute
  #checkov:skip=CKV_AZURE_99:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  #checkov:skip=CKV_AZURE_101:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  #checkov:skip=CKV_AZURE_100:Microsoft-managed keys; customer-managed keys need Key Vault and rotation, out of scope for the sandbox (documented)
  name                = "cosmos-grc-evidence-${random_string.suffix.result}"
  location            = var.location
  resource_group_name = local.evidence_rg
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  # Identity-only access: no key-based auth against the evidence database.
  # local_authentication_disabled was deprecated in favour of local_authentication_enabled
  # (removed in azurerm v5.0); the boolean inverts, so disabled=true becomes enabled=false.
  local_authentication_enabled = false

  # Key-based clients cannot change databases or containers (CKV_AZURE_132).
  access_key_metadata_writes_enabled = false

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }

  tags = local.common_tags
}

resource "azurerm_cosmosdb_sql_database" "grc" {
  name                = "grc"
  resource_group_name = local.evidence_rg
  account_name        = azurerm_cosmosdb_account.evidence.name
}

# assessments: one document per finding per run. Partitioned by subscription+date query pattern.
resource "azurerm_cosmosdb_sql_container" "assessments" {
  name                = "assessments"
  resource_group_name = local.evidence_rg
  account_name        = azurerm_cosmosdb_account.evidence.name
  database_name       = azurerm_cosmosdb_sql_database.grc.name
  partition_key_paths = ["/subscriptionId"]
}

# identities: one document per role assignment per run (capstone role-assignment collector).
# Same partition key as assessments, so FAFO's other subscriptions partition the same way.
resource "azurerm_cosmosdb_sql_container" "identities" {
  name                = "identities"
  resource_group_name = local.evidence_rg
  account_name        = azurerm_cosmosdb_account.evidence.name
  database_name       = azurerm_cosmosdb_sql_database.grc.name
  partition_key_paths = ["/subscriptionId"]
}

# frameworks: CSF 2.0 / 800-53 catalogs as records we own.
resource "azurerm_cosmosdb_sql_container" "frameworks" {
  name                = "frameworks"
  resource_group_name = local.evidence_rg
  account_name        = azurerm_cosmosdb_account.evidence.name
  database_name       = azurerm_cosmosdb_sql_database.grc.name
  partition_key_paths = ["/frameworkId"]
}

# mappings: the crosswalk — which assessment satisfies which control in which framework.
resource "azurerm_cosmosdb_sql_container" "mappings" {
  name                = "mappings"
  resource_group_name = local.evidence_rg
  account_name        = azurerm_cosmosdb_account.evidence.name
  database_name       = azurerm_cosmosdb_sql_database.grc.name
  partition_key_paths = ["/frameworkId"]
}

# --- Evidence artifact storage: WORM reports container, zero shared keys. ---

resource "azurerm_storage_account" "evidence" {
  #checkov:skip=CKV_AZURE_33:no queues in the evidence account
  #checkov:skip=CKV_AZURE_59:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  #checkov:skip=CKV_AZURE_206:LRS in the sandbox; production evidence would use GRS (documented)
  #checkov:skip=CKV2_AZURE_33:Y1 Consumption plan cannot use VNet integration or private endpoints, so access is identity-only (documented in CONTROLS.md)
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys; customer-managed keys need Key Vault and rotation, out of scope for the sandbox (documented)
  name                     = "stgrcevid${random_string.suffix.result}"
  resource_group_name      = local.evidence_rg
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # The store's front door has one kind of lock: identity.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "reports" {
  #checkov:skip=CKV2_AZURE_21:blob read, write and delete logs go to law-grc-sandbox via azurerm_monitor_diagnostic_setting.evidence_blob_access; this check does not count diagnostic settings
  name               = "reports"
  storage_account_id = azurerm_storage_account.evidence.id
}

# WORM: write once, read many. Not access control — a platform guarantee.
resource "azurerm_storage_container_immutability_policy" "reports_worm" {
  # resource_manager_id was deprecated on azurerm_storage_container; id now returns the
  # resource-manager ID this argument expects.
  storage_container_resource_manager_id = azurerm_storage_container.reports.id
  immutability_period_in_days           = var.reports_retention_days
  # Unlocked for the course so teardown works. Production locks it — after which
  # nobody, including Microsoft, can shorten or remove it.
}

# The deployer needs blob DATA-plane access to verify WORM behavior and upload seeds —
# Owner is control-plane only (the 01_02 lesson, in production form).
data "azurerm_client_config" "current" {}

locals {
  # Fixed deployer, so CI plans (gate, drift) do not swap it to the CI identity.
  # Unset: whoever runs plan, as before.
  deployer_principal_id = coalesce(var.deployer_principal_id, data.azurerm_client_config.current.object_id)
}

resource "azurerm_role_assignment" "deployer_blob_data" {
  scope                = azurerm_storage_account.evidence.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.deployer_principal_id
}

# Humans read evidence; only the collector writes it (SoD). The deployer gets Cosmos
# Data Reader on the account, and Data Contributor only on the reference-data
# containers labs/04's seed script fills. No write to assessments or identities.
resource "azurerm_cosmosdb_sql_role_assignment" "deployer_cosmos_read" {
  resource_group_name = local.evidence_rg
  account_name        = azurerm_cosmosdb_account.evidence.name
  role_definition_id  = "${azurerm_cosmosdb_account.evidence.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001"
  principal_id        = local.deployer_principal_id
  scope               = azurerm_cosmosdb_account.evidence.id
}

resource "azurerm_cosmosdb_sql_role_assignment" "deployer_cosmos_seed" {
  for_each            = toset([azurerm_cosmosdb_sql_container.frameworks.name, azurerm_cosmosdb_sql_container.mappings.name])
  resource_group_name = local.evidence_rg
  account_name        = azurerm_cosmosdb_account.evidence.name
  role_definition_id  = "${azurerm_cosmosdb_account.evidence.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = local.deployer_principal_id
  scope               = "${azurerm_cosmosdb_account.evidence.id}/dbs/${azurerm_cosmosdb_sql_database.grc.name}/colls/${each.key}"
}

# Who read, wrote or deleted evidence blobs (reports container), in the GRC workspace.
# Blob-service level: the account-level setting from the DINE policy carries metrics only.
resource "azurerm_monitor_diagnostic_setting" "evidence_blob_access" {
  name                       = "evidence-blob-access"
  target_resource_id         = "${azurerm_storage_account.evidence.id}/blobServices/default"
  log_analytics_workspace_id = data.terraform_remote_state.foundation.outputs.log_analytics_workspace_id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}
