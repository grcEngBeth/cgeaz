# Gate rule: no broad role grants sneak into governance code — not even yours,
# not even at 2 AM with a deadline.
# Broad = can do anything (Owner, Contributor) or can grant any role to anyone
# (User Access Administrator, Role Based Access Control Administrator).
# Terraform accepts a role by name or by ID, so both are checked. Built-in role
# IDs are the same in every tenant (verified with az role definition list).
package main

import rego.v1

broad_roles := {
	"owner": "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
	"contributor": "b24988ac-6180-42a0-ab88-20f7382dd24c",
	"user access administrator": "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9",
	"role based access control administrator": "f58310d9-a9f6-439a-9e8d-f62e7b41a168",
}

# A role assignment being created or updated (deletes are allowed, so teardown works).
granting(rc) if {
	rc.type == "azurerm_role_assignment"
	some action in rc.change.actions
	action != "delete"
}

deny contains msg if {
	some rc in input.resource_changes
	granting(rc)
	name := rc.change.after.role_definition_name
	is_string(name)
	broad_roles[lower(name)]
	msg := sprintf("%s: %s is a broad role (can do anything or grant any role); use a granular role", [rc.address, name])
}

deny contains msg if {
	some rc in input.resource_changes
	granting(rc)
	id := rc.change.after.role_definition_id
	is_string(id)
	some name, guid in broad_roles
	endswith(lower(id), concat("", ["/roledefinitions/", guid]))
	msg := sprintf("%s: role ID %s is %s, a broad role (can do anything or grant any role); use a granular role", [rc.address, guid, name])
}
