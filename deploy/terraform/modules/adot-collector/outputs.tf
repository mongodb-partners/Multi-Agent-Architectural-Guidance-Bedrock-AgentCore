output "config_s3_uri" {
  value       = "s3://${var.shared_bucket_name}/${local.config_s3_key}"
  description = "S3 URI of the rendered ADOT collector config. user_data.sh aws s3 cp's this on boot and on re-deploy."
}

output "config_s3_bucket" {
  value       = var.shared_bucket_name
  description = "S3 bucket holding the collector config (echoed for convenience)."
}

output "config_s3_key" {
  value       = local.config_s3_key
  description = "S3 key of the collector config."
}

output "config_etag" {
  value       = aws_s3_object.config.etag
  description = "MD5 etag of the rendered config — wire into user_data triggers if you want to force a sidecar restart on every config change."
}

output "otel_log_group_name" {
  value       = aws_cloudwatch_log_group.otel.name
  description = "Destination CW Logs group for OTLP-shipped application logs."
}

output "otel_log_group_arn" {
  value       = aws_cloudwatch_log_group.otel.arn
  description = "ARN of the OTLP application logs group."
}
