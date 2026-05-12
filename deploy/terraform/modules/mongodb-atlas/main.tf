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
# IP Access List — open access for Bedrock KB and POC clients
# Bedrock connects to Atlas from AWS service IPs that vary; for a POC we allow
# 0.0.0.0/0. Tighten before any production use.
# =============================================================================

resource "mongodbatlas_project_ip_access_list" "open" {
  project_id = var.atlas_project_id
  cidr_block = "0.0.0.0/0"
  comment    = "POC - allow Bedrock + all clients"
}
