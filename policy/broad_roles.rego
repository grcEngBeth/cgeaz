# Gate rule: no broad role grants sneak into governance code — not even yours,
# not even at 2 AM with a deadline.
# Broad = can do anything (Owner, Contributor) or can grant any role to anyone
# (User Access Administrator, Role Based Access Control Administrator).
# Terraform accepts a role by name or by ID, so both are checked. Built-in role
# IDs are the same in every tenant (verified with az role definition list).
package main

import rego.v1

# Broad roles by name (role_definition_name).
broad_role_names := {
	"owner",
	"contributor",
	"user access administrator",
	"role based access control administrator",
}

# The same roles by built-in ID (role_definition_id), names in comments. Kept apart
# from the names so no line pairs a role name with an ID: the gitleaks generic-api-key
# rule flagged that pattern (capstone result, Nov 17).
broad_role_ids := {
	"8e3af657-a8ff-443c-a75c-2fe8c4bcb635", # Owner
	"b24988ac-6180-42a0-ab88-20f7382dd24c", # Contributor
	"18d7d88d-d35e-4fb5-a5c3-7773c20a72d9", # User Access Administrator
	"f58310d9-a9f6-439a-9e8d-f62e7b41a168", # Role Based Access Control Administrator
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
	lower(name) in broad_role_names
	msg := sprintf("%s: %s is a broad role (can do anything or grant any role); use a granular role", [rc.address, name])
}

deny contains msg if {
	some rc in input.resource_changes
	granting(rc)
	id := rc.change.after.role_definition_id
	is_string(id)
	some guid in broad_role_ids
	endswith(lower(id), concat("", ["/roledefinitions/", guid]))
	msg := sprintf("%s: role ID %s is a broad role (can do anything or grant any role); use a granular role", [rc.address, guid])
}
