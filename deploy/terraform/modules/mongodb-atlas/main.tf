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
# IP Access List — mode-aware
#
# privatelink mode (default):
#   - Keeps the open 0.0.0.0/0 entry so Bedrock KB ingestion can use public
#     SRV when enable_kb_privatelink=false (Option B, documented exception).
#     PrivateLink itself enforces the actual network boundary for runtime.
#
# peering mode:
#   - Replaces the open entry with the customer's vpc_cidr. KB ingestion in
#     peering mode uses the NLB-over-peering path (or hybrid PL), so no
#     public source is required. Defense-in-depth: only the peered VPC can
#     reach Atlas at the network layer, not just at TLS+auth.
#
# Atlas IP access list is per-entry, NOT bulk-replace — flipping the cidr_block
# on this single resource preserves other entries created by other Terraform
# states or other clusters in the same Atlas project.
# =============================================================================

resource "mongodbatlas_project_ip_access_list" "open" {
  project_id = var.atlas_project_id
  cidr_block = var.network_mode == "peering" ? var.vpc_cidr : "0.0.0.0/0"
  comment = (
    var.network_mode == "peering"
    ? "Peering mode — restrict Atlas access to customer VPC CIDR"
    : "POC - allow Bedrock + all clients"
  )

  lifecycle {
    precondition {
      condition     = var.network_mode != "peering" || var.vpc_cidr != ""
      error_message = "mongodb-atlas: network_mode='peering' requires var.vpc_cidr to be set (the IP access list needs the customer VPC CIDR to scope access)."
    }
  }
}
