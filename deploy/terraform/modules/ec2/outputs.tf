output "public_ip" {
  value       = aws_eip.app.public_ip
  description = "Elastic IP address — stable public IP for the POC instance"
}

output "instance_id" {
  value       = aws_instance.app.id
  description = "EC2 instance ID"
}

output "api_url" {
  value       = "http://${aws_eip.app.public_ip}:3000"
  description = "Hono/Bun API base URL"
}

output "ui_url" {
  value       = "http://${aws_eip.app.public_ip}:8501"
  description = "Streamlit UI URL"
}

output "ssh_command" {
  value       = "ssh ec2-user@${aws_eip.app.public_ip}"
  description = "SSH command to connect (requires key pair set in ec2_key_pair_name variable)"
}

output "ssm_command" {
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
  description = "SSM Session Manager command — connect without a key pair"
}

output "deploy_target" {
  value       = "ec2-user@${aws_eip.app.public_ip}:/opt/multiagent"
  description = "rsync target for deploy.sh code sync"
}

output "security_group_id" {
  value       = aws_security_group.ec2.id
  description = "Security group ID of the EC2 instance"
}
