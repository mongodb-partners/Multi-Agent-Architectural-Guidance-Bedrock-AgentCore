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
  description = "AWS region where the VPC endpoint is created"
}

variable "atlas_project_id" {
  type        = string
  sensitive   = true
  description = "MongoDB Atlas project ID (from Atlas console → Project Settings)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the Atlas VPC endpoint is created"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block allowed to reach Atlas PrivateLink endpoint ports. Used directly as the SG ingress source for ports 27017 / 443 / 1024-65535 — no per-app SG references."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs where the Atlas VPC endpoint ENIs are placed"
}
