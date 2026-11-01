# TEST ONLY: deliberately non-compliant. Never merge.
resource "azurerm_storage_account" "bad" {
  name                            = "stbadgatetest01"
  resource_group_name             = "rg-grc-sandbox-dev"
  location                        = "eastus"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = true
}
