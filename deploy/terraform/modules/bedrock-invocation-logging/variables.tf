variable "project_name" {
  type        = string
  description = "Operator/team project name. Used only for the Project tag — resource names use shared_resource_prefix so multiple per-project envs/ec2 stacks can share the singleton Bedrock invocation logging stack owned by envs/shared."
}

variable "shared_resource_prefix" {
  type        = string
  description = "Prefix used in the IAM role name (\"$${prefix}-bedrock-invocation-logging-<env>\") and the Data Protection Policy name (\"$${prefix}-<env>-bedrock-pii\"). Passed in from envs/shared so renaming \"multiagent\" → anything else is one-variable change. Must be stable per (account, region, environment) because Bedrock invocation logging is an account-scoped singleton."
  default     = "multiagent"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)."
}

variable "enable" {
  type        = bool
  description = "Master switch. false leaves the (account-scoped) invocation logging configuration untouched — use when another stack in the same account already owns it."
  default     = true
}

variable "log_prompt_bodies" {
  type        = bool
  description = "Deliver raw prompt + completion bodies to CloudWatch. Defaults to FALSE for privacy. Flip to true per-environment only with explicit security sign-off; the Data Protection Policy still scrubs PII, but the body still gets written before being scrubbed."
  default     = false
}

variable "log_embedding_bodies" {
  type        = bool
  description = "Deliver raw embedding input text to CloudWatch. Defaults to FALSE — embeddings can encode user text and so leak semantically. Same caveat as log_prompt_bodies."
  default     = false
}

variable "log_group_name" {
  type        = string
  description = "Log group name. Default /aws/bedrock/invocations matches the AWS-documented convention so GenAI Observability auto-discovers it."
  default     = "/aws/bedrock/invocations"
}

variable "retention_days" {
  type        = number
  description = "Retention for the invocation log group. Default 7 dev. Set to 30+ in prod, more for regulated industries."
  default     = 7
}

variable "data_protection_identifiers" {
  type        = list(string)
  description = "Managed PII identifiers to Audit + Deidentify. Defaults cover region/language-independent PII (always valid). Add country-scoped identifiers per environment as needed: e.g. PhoneNumber-US, PhoneNumber-GB, BankAccountNumber-US, Ssn. Full list: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL-managed-data-identifiers.html"
  default = [
    # Language- + region-independent. These are the safe defaults that work
    # in every region without `InvalidParameterException`. The country-scoped
    # ones (PhoneNumber-US, Ssn, BankAccountNumber-US, etc.) must be added
    # explicitly by ops once the deployment region is known.
    "EmailAddress",
    "CreditCardNumber",
    "AwsSecretKey",
    "IpAddress",
  ]
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged onto every resource."
  default     = {}
}
