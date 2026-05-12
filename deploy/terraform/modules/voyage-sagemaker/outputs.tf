output "endpoint_name" {
  description = "SageMaker endpoint name — set as VOYAGE_SAGEMAKER_ENDPOINT in the API"
  value       = aws_sagemaker_endpoint.voyage.name
}

output "endpoint_arn" {
  description = "SageMaker endpoint ARN"
  value       = aws_sagemaker_endpoint.voyage.arn
}

output "execution_role_arn" {
  description = "IAM role used by the SageMaker endpoint"
  value       = aws_iam_role.sagemaker_exec.arn
}
