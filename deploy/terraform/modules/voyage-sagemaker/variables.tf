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
  description = "Deployment environment"
}

variable "voyage_model_package_arn" {
  type        = string
  description = <<EOT
AWS Marketplace model package ARN for Voyage AI.
Subscribe at: https://aws.amazon.com/marketplace/seller-profile?id=voyage-ai
Then find the ARN in SageMaker > JumpStart or via:
  aws sagemaker list-model-packages --model-package-group-name voyage-3
Typical ARN pattern:
  arn:aws:sagemaker:us-east-1:865070037744:model-package/voyage-3-v1-<hash>
EOT
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
