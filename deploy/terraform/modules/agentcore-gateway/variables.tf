variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "project_name" {
  type        = string
  description = "Resource name prefix"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "lambda_function_arn" {
  type        = string
  description = <<-EOT
    Lambda function ARN to register as the default MCP tool target. When empty
    (the default), the Gateway is created WITHOUT any target — useful when the
    Lambda is blocked (SCP) or the target is provisioned out-of-band (e.g.
    OpenAPI target pointing at an HTTPS endpoint later). See
    Docs/adr/0001-mcp-on-ec2-not-lambda.md.
  EOT
  default     = ""
}

variable "create_lambda_target" {
  type        = bool
  description = "Set to true to create the Lambda-invoke IAM policy and register the Lambda as a Gateway target. Must be a static value (not derived from a resource output) so Terraform can evaluate count at plan time."
  default     = false
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Cognito User Pool ID (used as JWT authorizer issuer)"
}

variable "cognito_app_client_id" {
  type        = string
  description = "Cognito app client ID (used as JWT authorizer audience)"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the Gateway (passed through to create-gateway --tags)"
  default     = {}
}
