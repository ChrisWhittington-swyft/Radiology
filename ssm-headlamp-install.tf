# SSM document that creates Headlamp OIDC secret from AWS Cognito

resource "aws_ssm_document" "headlamp_secret" {
  name          = "headlamp-create-secret"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Create/refresh headlamp OIDC secret from AWS Cognito (Secrets Manager + SSM)",
    parameters = {
      Region           = { type = "String", default = local.effective_region }
      ClusterName      = { type = "String", default = module.envs[local.primary_env].eks_cluster_name }
      CognitoSecretArn = { type = "String", default = "" }  # Pass ARN of Cognito client secret in Secrets Manager
      CognitoClientId  = { type = "String", default = "" }  # Cognito App Client ID
      CognitoIssuerUrl = { type = "String", default = "" }  # e.g., https://cognito-idp.us-east-1.amazonaws.com/<pool-id>
    },
    mainSteps = [
      {
        action = "aws:runShellScript",
        name   = "CreateHeadlampSecret",
        inputs = {
          runCommand = [
            "set -eo pipefail",
            "exec 2>&1",

            # Params
            "REGION='{{ Region }}'",
            "CLUSTER='{{ ClusterName }}'",
            "COGNITO_SECRET_ARN='{{ CognitoSecretArn }}'",
            "COGNITO_CLIENT_ID='{{ CognitoClientId }}'",
            "COGNITO_ISSUER_URL='{{ CognitoIssuerUrl }}'",

            # Kubeconfig
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",
            "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\"",

            # Get Cognito client secret from Secrets Manager
            "echo \"[Headlamp] Fetching Cognito client secret from Secrets Manager...\"",
            "if [ -n \"$COGNITO_SECRET_ARN\" ]; then",
            "  COGNITO_CLIENT_SECRET=$(aws secretsmanager get-secret-value --secret-id \"$COGNITO_SECRET_ARN\" --query SecretString --output text)",
            "else",
            "  echo \"[Headlamp] WARNING: No CognitoSecretArn provided, using empty secret (will fail auth)\"",
            "  COGNITO_CLIENT_SECRET=\"\"",
            "fi",

            # Ensure namespace exists
            "kubectl get ns headlamp 2>/dev/null || kubectl create ns headlamp",

            # Create/replace Secret
            "kubectl -n headlamp create secret generic headlamp-oidc \\",
            "  --from-literal=clientSecret=\"$${COGNITO_CLIENT_SECRET}\" \\",
            "  --from-literal=clientId=\"$${COGNITO_CLIENT_ID}\" \\",
            "  --from-literal=issuerUrl=\"$${COGNITO_ISSUER_URL}\" \\",
            "  --dry-run=client -o yaml | kubectl apply -f -",
            "echo '[Headlamp] Created/updated Secret headlamp/headlamp-oidc'",
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "headlamp_secret_now" {
  name = aws_ssm_document.headlamp_secret.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region           = local.effective_region
    ClusterName      = module.envs[local.primary_env].eks_cluster_name
    CognitoSecretArn = try(local.environments[local.primary_env].headlamp.cognito_secret_arn, "")
    CognitoClientId  = try(local.environments[local.primary_env].headlamp.cognito_client_id, "")
    CognitoIssuerUrl = try(local.environments[local.primary_env].headlamp.cognito_issuer_url, "")
  }

  depends_on = [
    aws_ssm_association.install_argocd_now,   # argo installed
    aws_ssm_association.argocd_ingress_now,   # ingress is up
  ]
}
