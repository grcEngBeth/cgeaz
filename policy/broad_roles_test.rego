# Unit tests for broad_roles.rego. Run: conftest verify -p policy
package main

import rego.v1

grant(type, actions, after) := {"resource_changes": [{
	"address": "test.grant",
	"type": type,
	"change": {"actions": actions, "after": after},
}]}

broad_denied(inp) if {
	some msg in deny with input as inp
	contains(msg, "is a broad role")
}

broad_denied(inp) if {
	some msg in deny with input as inp
	contains(msg, "a broad role (")
}

by_name(name) := grant("azurerm_role_assignment", ["create"], {"role_definition_name": name})

by_id(guid) := grant("azurerm_role_assignment", ["create"], {"role_definition_id": concat("", [
	"/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/", guid,
])})

# Denied: each broad role by name, and by ID
test_owner_by_name if broad_denied(by_name("Owner"))
test_contributor_by_name if broad_denied(by_name("Contributor"))
test_uaa_by_name if broad_denied(by_name("User Access Administrator"))
test_rbac_admin_by_name if broad_denied(by_name("Role Based Access Control Administrator"))
test_owner_by_id if broad_denied(by_id("8e3af657-a8ff-443c-a75c-2fe8c4bcb635"))
test_uaa_by_id if broad_denied(by_id("18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"))
test_rbac_admin_by_id_uppercase if broad_denied(by_id("F58310D9-A9F6-439A-9E8D-F62E7B41A168"))
test_update_still_checked if broad_denied(grant("azurerm_role_assignment", ["update"], {"role_definition_name": "Owner"}))

# Allowed: granular roles, a custom role ID, teardown, Cosmos data-plane roles
test_granular_name_allowed if not broad_denied(by_name("Storage Blob Data Contributor"))
test_custom_role_id_allowed if not broad_denied(by_id("11111111-2222-3333-4444-555555555555"))
test_delete_owner_allowed if not broad_denied(grant("azurerm_role_assignment", ["delete"], {}))
test_cosmos_sql_role_allowed if not broad_denied(grant("azurerm_cosmosdb_sql_role_assignment", ["create"], {"role_definition_id": "x/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"}))
test_contributor_by_id if broad_denied(by_id("b24988ac-6180-42a0-ab88-20f7382dd24c"))
