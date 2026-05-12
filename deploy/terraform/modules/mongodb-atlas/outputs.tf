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
