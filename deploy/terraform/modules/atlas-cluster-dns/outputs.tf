output "route53_zone_id" {
  value       = aws_route53_zone.atlas.zone_id
  description = "Private hosted zone ID for the Atlas cluster's SRV hostname."
}
