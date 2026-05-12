output "function_arn" {
  value       = aws_lambda_function.mcp.arn
  description = "ARN of the MongoDB MCP Lambda function (use as AgentCore Gateway target)"
}

output "function_name" {
  value       = aws_lambda_function.mcp.function_name
  description = "Lambda function name"
}

output "role_arn" {
  value       = aws_iam_role.lambda.arn
  description = "Lambda execution role ARN"
}

output "security_group_id" {
  value       = aws_security_group.lambda.id
  description = "Lambda security group ID — grant ingress from this SG on Atlas PrivateLink SG"
}

output "artifact_bucket_name" {
  value       = aws_s3_object.lambda_artifact.bucket
  description = "S3 bucket holding the deployed Lambda zip artifact"
}

output "artifact_key" {
  value       = aws_s3_object.lambda_artifact.key
  description = "S3 object key for the deployed Lambda zip artifact"
}
