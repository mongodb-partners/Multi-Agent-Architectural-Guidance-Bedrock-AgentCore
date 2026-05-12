output "user_pool_id" {
  description = "ID of the Cognito User Pool"
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  description = "ARN of the Cognito User Pool"
  value       = aws_cognito_user_pool.main.arn
}

output "user_pool_client_id" {
  description = "ID of the Cognito User Pool App Client"
  value       = aws_cognito_user_pool_client.app.id
}

output "user_pool_endpoint" {
  description = "Endpoint of the Cognito User Pool (used as the issuer URL)"
  value       = aws_cognito_user_pool.main.endpoint
}

output "user_pool_domain" {
  description = "Cognito hosted-UI domain prefix"
  value       = aws_cognito_user_pool_domain.main.domain
}

output "jwks_uri" {
  description = "JWKS endpoint for verifying Cognito-issued JWTs"
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
}
