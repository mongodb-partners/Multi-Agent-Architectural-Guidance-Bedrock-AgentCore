variable "project_name" {
  type        = string
  description = "Project name prefix used for resource naming + Project tag."
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
