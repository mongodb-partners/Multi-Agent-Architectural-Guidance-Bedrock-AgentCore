output "api_repository_url" {
  description = "ECR repository URL for the API image"
  value       = aws_ecr_repository.api.repository_url
}

output "ui_repository_url" {
  description = "ECR repository URL for the UI image"
  value       = aws_ecr_repository.ui.repository_url
}

output "registry_id" {
  description = "ECR registry ID (AWS account ID)"
  value       = aws_ecr_repository.api.registry_id
}
