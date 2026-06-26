terraform {
  required_providers {
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "~> 1.14"
    }
  }
}

# =============================================================================
# Atlas M10 Cluster
# M10 is the minimum tier that supports Atlas Vector Search indexes.
# Creation takes ~5-10 minutes on first apply.
# =============================================================================

resource "mongodbatlas_cluster" "main" {
  # BYO: operator owns the cluster — create nothing.
  count = var.cluster_source == "managed" ? 1 : 0

  project_id = var.atlas_project_id
  name       = var.cluster_name

  cluster_type = "REPLICASET"

  replication_specs {
    num_shards = 1
    regions_config {
      region_name     = "US_EAST_1"
      electable_nodes = 3
      priority        = 7
      read_only_nodes = 0
    }
  }

  provider_name               = "AWS"
  provider_region_name        = "US_EAST_1"
  provider_instance_size_name = "M10"
  mongo_db_major_version      = "7.0"

  # Enable backup for safety even on POC
  cloud_backup = false

  auto_scaling_disk_gb_enabled = false

  tags {
    key   = "Project"
    value = var.project_tag
  }
}

# =============================================================================
# Database User
# =============================================================================

resource "mongodbatlas_database_user" "app" {
  # BYO: operator manages their own DB users.
  count = var.cluster_source == "managed" ? 1 : 0

  project_id         = var.atlas_project_id
  username           = var.db_username
  password           = var.db_password
  auth_database_name = "admin"

  roles {
    role_name     = "readWrite"
    database_name = var.db_name
  }

  # Also grant readWrite on admin for seeding operations
  roles {
    role_name     = "readWrite"
    database_name = "admin"
  }

  depends_on = [mongodbatlas_cluster.main]
}

# =============================================================================
# IP Access List — mode-aware, and NEVER 0.0.0.0/0 (no public-internet path)
#
# Goal: Atlas is reachable only from where it was created from / the deployment
# fabric — not the open internet. We never add a 0.0.0.0/0 entry.
#
# privatelink mode (default):
#   - Scope the public-SRV allowlist to the deploy machine's public IP
#     (var.operator_ip_cidr — "anywhere it was created from"). Runtime traffic
#     reaches Atlas over the PrivateLink endpoint, which BYPASSES the project IP
#     access list entirely, so the only public-SRV consumers are operator-run
#     local-exec provisioners (db-seeding, ensure-collection, KB ingestion-status
#     polls, post-deploy smoke). No 0.0.0.0/0 entry is created.
#   - Caveat: enable_kb_privatelink=false (Option B — KB ingestion over public
#     SRV) is no longer reachable through this allowlist because Bedrock's source
#     IPs are AWS-managed/variable. Keep enable_kb_privatelink=true (the default,
#     partner-validated path), which routes KB ingestion through the VPCE.
#
# peering mode:
#   - Scope the allowlist to the customer's vpc_cidr (defense-in-depth: only the
#     peered VPC can reach Atlas at the network layer). KB ingestion uses the
#     NLB-over-peering path, so no public source is required. The operator
#     laptop /32 is added separately by modules/atlas-vpc-peering.
#
# Atlas IP access list is per-entry, NOT bulk-replace — these single entries
# preserve other entries created by other Terraform states or other clusters in
# the same Atlas project.
# =============================================================================

resource "mongodbatlas_project_ip_access_list" "peering_vpc" {
  # BYO: never touch the customer's access list (they own it).
  count      = var.cluster_source == "managed" && var.network_mode == "peering" ? 1 : 0
  project_id = var.atlas_project_id
  cidr_block = var.vpc_cidr
  # NOTE: Atlas caps access-list comments at 80 chars; keep short + ASCII.
  comment = "Peering mode: restrict Atlas access to customer VPC CIDR"

  lifecycle {
    precondition {
      condition     = var.vpc_cidr != ""
      error_message = "mongodb-atlas: network_mode='peering' requires var.vpc_cidr to be set (the IP access list needs the customer VPC CIDR to scope access)."
    }
  }
}

resource "mongodbatlas_project_ip_access_list" "operator" {
  # BYO: never touch the customer's access list (they own it).
  count      = var.cluster_source == "managed" && var.network_mode == "privatelink" && var.operator_ip_cidr != "" ? 1 : 0
  project_id = var.atlas_project_id
  cidr_block = var.operator_ip_cidr
  # NOTE: Atlas rejects access-list comments longer than 80 characters
  # (HTTP 400 INVALID_NETWORK_PERMISSION_COMMENT). Keep this short + ASCII.
  comment = "PrivateLink: Atlas allowed only from deploy machine (operator IP)"
}

# Guard (warning, non-fatal): in privatelink mode with no operator IP the
# project would have NO public-SRV allowlist entry, so operator-run local-exec
# provisioners can't reach Atlas. Deploy scripts auto-detect the operator IP,
# so this should only surface on hand-rolled applies.
check "atlas_privatelink_has_operator_ip" {
  assert {
    condition     = var.cluster_source != "managed" || var.network_mode != "privatelink" || var.operator_ip_cidr != ""
    error_message = "mongodb-atlas: network_mode='privatelink' but operator_ip_cidr is empty — the Atlas IP access list will have NO public-SRV entry, so operator-run local-exec provisioners (db-seeding, KB ingestion-status polls, post-deploy smoke) cannot reach Atlas. Set OPERATOR_IP_CIDR (deploy-project.sh / deploy-local.sh auto-detect it via checkip.amazonaws.com)."
  }
}
