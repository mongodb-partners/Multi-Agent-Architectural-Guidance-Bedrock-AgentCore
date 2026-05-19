output "dashboard_name" {
  value       = aws_cloudwatch_dashboard.atlas.dashboard_name
  description = "CloudWatch dashboard name."
}
