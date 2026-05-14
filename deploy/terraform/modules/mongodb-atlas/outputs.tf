output "cluster_name" {
  value       = mongodbatlas_cluster.main.name
  description = "Atlas cluster name"
}

output "srv_address" {
  value       = mongodbatlas_cluster.main.connection_strings[0].standard_srv
  description = "Full mongodb+srv:// connection string (without credentials)"
}

output "connection_string" {
  value       = "mongodb+srv://${var.db_username}:${var.db_password}@${replace(mongodbatlas_cluster.main.connection_strings[0].standard_srv, "mongodb+srv://", "")}/?retryWrites=true&w=majority"
  sensitive   = true
  description = "Full Atlas connection string with credentials"
}

output "mongo_host" {
  value       = replace(mongodbatlas_cluster.main.connection_strings[0].standard_srv, "mongodb+srv://", "")
  description = "Atlas SRV hostname without scheme (e.g. cluster.xxxxx.mongodb.net)"
}

# ─── PrivateLink-direct connection string ──────────────────────────────────────
# For workloads that live in a private VPC and reach Atlas through PrivateLink
# (Lambda MCP, etc.). The SRV form (`connection_string` above) requires a public
# DNS lookup that fails inside a private VPC without a VPC DNS resolver pointing
# at Atlas's SRV zone — the symptom is `MongoAPIError: No addresses found at host`.
#
# This output picks the AWS PrivateLink endpoint matching var.privatelink_endpoint_id
# (when set), URL-encodes credentials, and appends `tlsAllowInvalidHostnames=true`
# because Atlas's per-region PrivateLink hostname (pl-X-us-east-1.<id>.mongodb.net)
# is not in the served TLS cert's SAN list. CA + chain + expiry verification remain
# enforced; only hostname matching is skipped — acceptable because the connection
# traverses an AWS-owned PrivateLink (private network, not the public internet).
#
# Returns "" when var.privatelink_endpoint_id is empty or no matching endpoint
# exists — callers should fall back to the SRV `connection_string` in that case.
locals {
  _pl_matches = [
    for pe in mongodbatlas_cluster.main.connection_strings[0].private_endpoint : pe.connection_string
    if length([for ep in pe.endpoints : ep.endpoint_id if ep.endpoint_id == var.privatelink_endpoint_id]) > 0
  ]
  _pl_srv_matches = [
    for pe in mongodbatlas_cluster.main.connection_strings[0].private_endpoint : pe.srv_connection_string
    if length([for ep in pe.endpoints : ep.endpoint_id if ep.endpoint_id == var.privatelink_endpoint_id]) > 0
  ]
  _pl_raw       = length(local._pl_matches) > 0 ? local._pl_matches[0] : ""
  _pl_srv_raw   = length(local._pl_srv_matches) > 0 ? local._pl_srv_matches[0] : ""
  _pl_authority = local._pl_raw == "" ? "" : split("/?", replace(local._pl_raw, "mongodb://", ""))[0]
  _pl_hosts     = local._pl_authority == "" ? [] : split(",", local._pl_authority)
  _pl_ports = [
    for host in local._pl_hosts : tonumber(regex(":([0-9]+)$", host)[0])
  ]
}

output "privatelink_connection_string" {
  value = local._pl_raw == "" ? "" : format(
    "mongodb://%s:%s@%s%stlsAllowInvalidHostnames=true",
    urlencode(var.db_username),
    urlencode(var.db_password),
    replace(local._pl_raw, "mongodb://", ""),
    can(regex("\\?", local._pl_raw)) ? "&" : "?"
  )
  sensitive   = true
  description = "Multi-host non-SRV PrivateLink connection string with credentials, suitable for VPC-internal callers (Lambda MCP). Empty string when var.privatelink_endpoint_id is unset or unmatched."
}

output "privatelink_srv_host" {
  value       = local._pl_srv_raw == "" ? "" : replace(local._pl_srv_raw, "mongodb+srv://", "")
  description = "Atlas PrivateLink SRV hostname without scheme (for example cluster-pl-0.xxxxx.mongodb.net). Empty when var.privatelink_endpoint_id is unset or unmatched."
}

output "privatelink_ports" {
  value       = local._pl_ports
  description = "Atlas PrivateLink listener ports advertised by the matching private endpoint connection string."
}
