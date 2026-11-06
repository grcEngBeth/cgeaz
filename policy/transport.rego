# Gate rule (capstone's own): data in transit is encrypted, enforced in code before merge.
# Same control as the cge-require-secure-transfer policy, which catches what Terraform didn't build.
# CSF 2.0: PR.DS-02. Attribute names are azurerm v4 (lock file pins 4.81.0).
package main

import rego.v1

function_app_types := {"azurerm_linux_function_app", "azurerm_windows_function_app"}

ok_storage_tls := {"TLS1_2", "TLS1_3"}

weak_app_tls := {"1.0", "1.1"}

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "azurerm_storage_account"
	rc.change.after.https_traffic_only_enabled == false
	msg := sprintf("%s: storage accounts must accept HTTPS only (https_traffic_only_enabled = true)", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "azurerm_storage_account"
	rc.change.after != null
	not rc.change.after.min_tls_version in ok_storage_tls
	msg := sprintf("%s: storage accounts must require TLS 1.2 or later (min_tls_version)", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in function_app_types
	rc.change.after != null
	not rc.change.after.https_only == true
	msg := sprintf("%s: Function Apps must set https_only = true (otherwise plain HTTP is served)", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in function_app_types
	some sc in rc.change.after.site_config
	sc.minimum_tls_version in weak_app_tls
	msg := sprintf("%s: Function Apps must not allow TLS below 1.2 (site_config.minimum_tls_version)", [rc.address])
}
