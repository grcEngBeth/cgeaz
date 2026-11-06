plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.33.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# prevent_destroy would block the course teardown (terraform destroy). Evidence is
# protected by the WORM immutability policy instead; production would also lock it.
rule "azurerm_resources_missing_prevent_destroy" {
  enabled = false
}
