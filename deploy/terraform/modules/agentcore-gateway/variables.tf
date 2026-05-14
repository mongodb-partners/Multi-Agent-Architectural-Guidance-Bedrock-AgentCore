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
  description = "Set to true to create the Lambda-invoke IAM policy and register the Lambda as a Gateway target. Must be a static value (not derived from a resource output) so Terraform can evaluate count at plan time. Mutually exclusive with create_mcp_server_target."
  default     = false
}

variable "create_mcp_server_target" {
  type        = bool
  description = "Set to true to register an AgentCore Runtime as an `mcpServer` Gateway target instead of a Lambda. The target endpoint comes from var.mcp_server_endpoint and the runtime ARN from var.mcp_server_runtime_arn. The Gateway IAM role is granted bedrock-agentcore:InvokeAgentRuntime on that ARN. Mutually exclusive with create_lambda_target."
  default     = false
}

variable "mcp_server_endpoint" {
  type        = string
  description = "Streamable-HTTP MCP endpoint of the AgentCore Runtime that hosts the tool surface, e.g. https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/<url-encoded-arn>/invocations?qualifier=DEFAULT. Used only when create_mcp_server_target=true."
  default     = ""
}

variable "mcp_server_runtime_arn" {
  type        = string
  description = "AgentCore Runtime ARN that the Gateway is allowed to invoke when create_mcp_server_target=true. Used solely as the Resource on the bedrock-agentcore:InvokeAgentRuntime IAM grant."
  default     = ""
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
