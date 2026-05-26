variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "environment" {
  type        = string
  description = "Deployment environment. Used in the endpoint + IAM role names (env-scoped, not project-scoped, since envs/shared owns this module)."
}

variable "voyage_model_package_arn" {
  type        = string
  description = <<EOT
AWS Marketplace model package ARN for Voyage AI.
Default target listing is voyage-multimodal-3.
Subscribe at: https://aws.amazon.com/marketplace/pp/prodview-hrid2zxusacxy
Then find the region-specific ARN via:
  aws sagemaker list-model-packages --model-package-group-name voyage-multimodal-3
Typical ARN pattern:
  arn:aws:sagemaker:us-east-1:865070037744:model-package/voyage-multimodal-3-<hash>
EOT
}

variable "endpoint_name_suffix" {
  type        = string
  description = "Suffix appended to the SageMaker endpoint name (e.g. \"voyage-multimodal-3\" or \"voyage-3-5-lite\"). Defaults to voyage-multimodal-3."
  default     = "voyage-multimodal-3"
}

variable "instance_type" {
  type        = string
  description = "SageMaker endpoint instance type (must be GPU; Voyage AI model packages require ml.g6.xlarge or ml.g5.xlarge)"
  default     = "ml.g6.xlarge"
}

variable "instance_count" {
  type        = number
  description = "Number of endpoint instances"
  default     = 1
}
