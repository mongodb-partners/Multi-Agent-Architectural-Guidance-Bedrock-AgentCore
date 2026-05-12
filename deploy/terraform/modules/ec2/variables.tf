variable "project_name" {
  type        = string
  description = "Project name prefix for resource names and tags"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID to launch the instance in"
}

variable "public_subnet_id" {
  type        = string
  description = "Public subnet ID — instance gets a public IP via Elastic IP"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type. t3.medium (2 vCPU / 4 GB) is the recommended minimum for running both API + UI."
  default     = "t3.medium"
}

variable "key_pair_name" {
  type        = string
  description = "Name of an existing EC2 key pair for SSH access. Leave empty to use SSM Session Manager instead (no key pair needed)."
  default     = ""
}

variable "ecr_api_image" {
  type        = string
  description = "Full ECR image URI for the API container (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/project-api:latest)"
  default     = ""
}

variable "ecr_ui_image" {
  type        = string
  description = "Full ECR image URI for the UI container (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/project-ui:latest)"
  default     = ""
}

variable "ecr_registry" {
  type        = string
  description = "ECR registry hostname for docker login (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com)"
  default     = ""
}
