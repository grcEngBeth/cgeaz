variable "location" {
  description = "Azure region for the evidence store. Default eastus2: East US frequently lacks Cosmos capacity and consumption-plan quota for new subscriptions."
  type        = string
  default     = "eastus2"
}

variable "environment" {
  description = "Environment name used in tags and resource names."
  type        = string
  default     = "dev"
}

variable "state_resource_group" {
  description = "Resource group holding the Terraform state storage account (from bootstrap.sh)."
  type        = string
  default     = "rg-grc-tfstate"
}

variable "state_storage_account" {
  description = "Terraform state storage account name (from bootstrap.sh / backend.hcl)."
  type        = string
}

variable "reports_retention_days" {
  description = "WORM retention on the reports container. 90 for the course; whatever your obligations demand in production."
  type        = number
  default     = 90
}

variable "functions_location" {
  description = "Region for the Function tier. Free-account consumption (Y1) quota is REGIONAL and zero in most US regions; centralus and westus3 had quota in validation. Probe with labs/00-setup/probe-quota.sh."
  type        = string
  default     = "centralus"
}

variable "deployer_principal_id" {
  description = "Object ID given deployer blob and Cosmos write access. Set in CI so plans do not depend on who runs them."
  type        = string
  default     = null
}

variable "owner_email" {
  description = "Accountable owner for subscription-level findings, which have no resource group owner tag. Same value as stage 01's owner tags (repo variable OWNER_EMAIL)."
  type        = string
}
