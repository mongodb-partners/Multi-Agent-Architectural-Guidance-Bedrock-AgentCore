output "public_ip" {
  value       = local.app_public_ip
  description = "Public IP for the application EC2 instance (Elastic IP unless network_mode='public', where it's the instance's auto-assigned IP)"
}

output "instance_id" {
  value       = aws_instance.app.id
  description = "EC2 instance ID"
}

output "api_url" {
  value       = "http://${local.app_public_ip}:3000"
  description = "Hono/Bun API base URL"
}

output "ui_url" {
  value       = "http://${local.app_public_ip}:8501"
  description = "Streamlit UI URL"
}

output "ssh_command" {
  value       = "ssh ec2-user@${local.app_public_ip}"
  description = "SSH command to connect (requires key pair set in ec2_key_pair_name variable)"
}

output "ssm_command" {
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
  description = "SSM Session Manager command — connect without a key pair"
}

output "deploy_target" {
  value       = "ec2-user@${local.app_public_ip}:/opt/multiagent"
  description = "rsync target for deploy.sh code sync"
}

output "security_group_id" {
  value       = aws_security_group.ec2.id
  description = "Security group ID of the EC2 instance"
}
