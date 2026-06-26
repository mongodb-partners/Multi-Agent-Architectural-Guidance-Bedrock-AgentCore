# All outputs branch on var.cluster_source. In 'managed' mode they derive from
# the Terraform-created cluster (today's behaviour). In 'byo' mode the cluster
# resource has count=0, so every reference must guard the [0] index — we return
# the operator-supplied passthrough values instead (connection_string + srv host),
# and "" / [] for the PrivateLink/peering forms (BYO+public has neither).
locals {
  _managed = var.cluster_source == "managed"
  # Single guarded handle to the cluster's connection_strings[0]; null under BYO.
  _cs = local._managed ? mongodbatlas_cluster.main[0].connection_strings[0] : null
}

output "cluster_name" {
  value       = local._managed ? mongodbatlas_cluster.main[0].name : var.cluster_name
  description = "Atlas cluster name (BYO: the configured cluster_name var)."
}

output "srv_address" {
  value       = local._managed ? local._cs.standard_srv : "mongodb+srv://${var.byo_srv_host}"
  description = "Full mongodb+srv:// connection string (without credentials)"
}

output "connection_string" {
  value       = local._managed ? "mongodb+srv://${urlencode(var.db_username)}:${urlencode(var.db_password)}@${replace(local._cs.standard_srv, "mongodb+srv://", "")}/?retryWrites=true&w=majority" : var.byo_connection_string
  sensitive   = true
  description = "Full Atlas connection string with credentials (BYO: var.byo_connection_string verbatim)."
}

output "mongo_host" {
  value       = local._managed ? replace(local._cs.standard_srv, "mongodb+srv://", "") : var.byo_srv_host
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
# exists, OR when cluster_source=byo (no Terraform-owned cluster to read from).
locals {
  _pl_matches = local._managed ? [
    for pe in local._cs.private_endpoint : pe.connection_string
    if length([for ep in pe.endpoints : ep.endpoint_id if ep.endpoint_id == var.privatelink_endpoint_id]) > 0
  ] : []
  _pl_srv_matches = local._managed ? [
    for pe in local._cs.private_endpoint : pe.srv_connection_string
    if length([for ep in pe.endpoints : ep.endpoint_id if ep.endpoint_id == var.privatelink_endpoint_id]) > 0
  ] : []
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
  description = "Multi-host non-SRV PrivateLink connection string with credentials, suitable for VPC-internal callers (Lambda MCP). Empty string when var.privatelink_endpoint_id is unset or unmatched, or when cluster_source=byo."
}

output "privatelink_srv_host" {
  value       = local._pl_srv_raw == "" ? "" : replace(local._pl_srv_raw, "mongodb+srv://", "")
  description = "Atlas PrivateLink SRV hostname without scheme (for example cluster-pl-0.xxxxx.mongodb.net). Empty when var.privatelink_endpoint_id is unset or unmatched, or when cluster_source=byo."
}

output "privatelink_ports" {
  value       = local._pl_ports
  description = "Atlas PrivateLink listener ports advertised by the matching private endpoint connection string. Empty under cluster_source=byo."
}

# ─── VPC Peering connection strings ───────────────────────────────────────────
# Peering uses different connection_strings[0] fields than PrivateLink:
#   - connection_strings[0].private       — multi-host non-SRV
#     (mongodb://shard-00-00.xxx-shard-0.xxxxx-pri.mongodb.net:27017,...)
#     Always populated once a peering connection exists for the cluster's
#     project + region.
#   - connection_strings[0].private_srv   — SRV form
#     (mongodb+srv://cluster.xxxxx-pri.mongodb.net)
#     ONLY populated when the Atlas project has "Enable Private DNS for
#     Peering" toggled on. The atlas-vpc-peering module auto-enables this via
#     enable-private-dns.sh, but if the API key lacks GROUP_OWNER scope the
#     toggle fails and this output stays empty. Runtime callers intentionally
#     use peering_connection_string (multi-host) to avoid SRV/TXT DNS lookup.
#
# NO `tlsAllowInvalidHostnames=true` here because peering hostnames are in the
# Atlas TLS SAN list (unlike the PrivateLink `pl-X-…` hostnames which need the
# flag).
#
# Returns "" when peering isn't configured / Atlas hasn't populated the field,
# or when cluster_source=byo (no Terraform-owned cluster to read from).
locals {
  # try() is preferred over lookup() for object attribute access — lookup() is
  # only guaranteed on map types, while connection_strings[0] is an object with
  # statically-defined attributes (Atlas TS provider schema). try() returns the
  # default when the attribute is unset OR null OR the underlying expression
  # errors (covers the "peering not yet active" race where Atlas hasn't yet
  # populated the field on the cluster doc, AND the BYO case where _cs is null).
  _peering_raw     = try(local._cs.private, "")
  _peering_srv_raw = try(local._cs.private_srv, "")

  # Strip mongodb+srv:// prefix from the SRV form so we can emit it with creds.
  _peering_srv_host = local._peering_srv_raw == "" ? "" : replace(local._peering_srv_raw, "mongodb+srv://", "")

  # Authority (host:port,host:port,...) for the multi-host non-SRV form.
  _peering_authority = local._peering_raw == "" ? "" : split("/?", replace(local._peering_raw, "mongodb://", ""))[0]
}

output "peering_connection_string" {
  value = local._peering_raw == "" ? "" : format(
    "mongodb://%s:%s@%s%sretryWrites=true&w=majority",
    urlencode(var.db_username),
    urlencode(var.db_password),
    replace(local._peering_raw, "mongodb://", ""),
    can(regex("\\?", local._peering_raw)) ? "&" : "?"
  )
  sensitive   = true
  description = "Multi-host non-SRV peering connection string with credentials. Always populated when an Atlas-side network peering exists for this cluster's project+region. Empty under cluster_source=byo. NO tlsAllowInvalidHostnames because peering hostnames are in the cert SAN list."
}

output "peering_srv_host" {
  value       = local._peering_srv_host
  description = "Atlas peering SRV hostname without scheme (e.g. cluster.xxxxx-pri.mongodb.net). Empty when 'Private DNS for Peering' is not enabled, or under cluster_source=byo."
}

output "peering_connection_srv_string" {
  value = local._peering_srv_raw == "" ? "" : format(
    "mongodb+srv://%s:%s@%s/?retryWrites=true&w=majority",
    urlencode(var.db_username),
    urlencode(var.db_password),
    local._peering_srv_host
  )
  sensitive   = true
  description = "SRV-form peering connection string with credentials. Empty when peering_srv_host is empty or under cluster_source=byo. Runtime callers should prefer peering_connection_string to avoid SRV/TXT DNS lookup."
}
