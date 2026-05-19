output "fleet_dashboard_url" {
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${local.fleet_dashboard_name}"
  description = "Direct console URL for the fleet dashboard."
}

output "mongo_dashboard_url" {
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${local.mongo_dashboard_name}"
  description = "Direct console URL for the Mongo dashboard."
}

output "cost_dashboard_url" {
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${local.cost_dashboard_name}"
  description = "Direct console URL for the cost dashboard."
}
