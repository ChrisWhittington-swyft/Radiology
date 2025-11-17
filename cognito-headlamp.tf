# AWS Cognito User Pool for Headlamp OIDC Authentication

resource "aws_cognito_user_pool" "headlamp" {
  name = "${lower(local.effective_tenant)}-${local.primary_env}-headlamp"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = false
  }

  tags = merge(
    local.tags,
    {
      Name = "${lower(local.effective_tenant)}-${local.primary_env}-headlamp-pool"
    }
  )
}

resource "aws_cognito_user_pool_domain" "headlamp" {
  domain       = "${lower(local.effective_tenant)}-headlamp"
  user_pool_id = aws_cognito_user_pool.headlamp.id
}

resource "aws_cognito_user_pool_client" "headlamp" {
  name         = "headlamp"
  user_pool_id = aws_cognito_user_pool.headlamp.id

  generate_secret = true

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "profile", "email"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]

  callback_urls = [
    "https://headlamp.${local.app_host}/oidc-callback"
  ]

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}

# Store the client secret in Secrets Manager
resource "aws_secretsmanager_secret" "headlamp_cognito" {
  name        = "${lower(local.effective_tenant)}-${local.primary_env}-headlamp-cognito-secret"
  description = "Cognito client secret for Headlamp OIDC"

  tags = merge(
    local.tags,
    {
      Name = "${lower(local.effective_tenant)}-${local.primary_env}-headlamp-cognito"
    }
  )
}

resource "aws_secretsmanager_secret_version" "headlamp_cognito" {
  secret_id     = aws_secretsmanager_secret.headlamp_cognito.id
  secret_string = aws_cognito_user_pool_client.headlamp.client_secret
}

# Outputs for reference
output "headlamp_cognito_user_pool_id" {
  value       = aws_cognito_user_pool.headlamp.id
  description = "Cognito User Pool ID for Headlamp"
}

output "headlamp_cognito_client_id" {
  value       = aws_cognito_user_pool_client.headlamp.id
  description = "Cognito App Client ID for Headlamp"
}

output "headlamp_cognito_issuer_url" {
  value       = "https://cognito-idp.${local.effective_region}.amazonaws.com/${aws_cognito_user_pool.headlamp.id}"
  description = "Cognito OIDC Issuer URL for Headlamp"
}

output "headlamp_cognito_secret_arn" {
  value       = aws_secretsmanager_secret.headlamp_cognito.arn
  description = "Secrets Manager ARN for Headlamp Cognito client secret"
}
