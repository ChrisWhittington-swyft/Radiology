resource "aws_ssm_document" "create_dockerhub_secret" {
  for_each = toset(local.enabled_environments)

  name          = "${lower(local.effective_tenant)}-${each.key}-create-dockerhub-secret"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Create or update docker-hub secret in the default namespace - per environment",
    parameters = {
      Environment = {
        type        = "String"
        description = "Environment name (prod, dev, etc.)"
      }
      Namespace = {
        type    = "String"
        default = "default"
      }
      SecretName = {
        type    = "String"
        default = "docker-hub-secret"
      }
    },
    mainSteps = [
      {
        action = "aws:runShellScript",
        name   = "CreateDockerHubSecret",
        inputs = {
          runCommand = [
            "set -euo pipefail",
            "ENV='{{ Environment }}'",
            "NS='{{ Namespace }}'",
            "SECRET='{{ SecretName }}'",
            "echo \"Starting DockerHub secret creation for environment: $ENV\"",

            # Lookup environment-specific values from SSM
            "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
            "CLUSTER=$(aws ssm get-parameter --name /terraform/envs/$ENV/cluster_name --query 'Parameter.Value' --output text --region $REGION)",
            "USER_PARAM=$(aws ssm get-parameter --name /terraform/envs/$ENV/dockerhub_user_param --query 'Parameter.Value' --output text --region $REGION)",
            "PASS_PARAM=$(aws ssm get-parameter --name /terraform/envs/$ENV/dockerhub_pass_param --query 'Parameter.Value' --output text --region $REGION)",

            "echo \"Configuration loaded for $ENV\"",
            "echo \"  Cluster: $CLUSTER\"",
            "echo \"  Namespace: $NS\"",

            # Kubeconfig env
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",
            "set -u",

            # Sanity checks
            "aws sts get-caller-identity 1>/dev/null",
            "aws eks describe-cluster --name \"$CLUSTER\" --region \"$REGION\" 1>/dev/null",

            # Build kubeconfig
            "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\"",

            # Ensure namespace exists
            "kubectl get ns \"$NS\" 2>/dev/null || kubectl create ns \"$NS\"",

            "DH_USER=$(aws ssm get-parameter --name \"$USER_PARAM\" --with-decryption --query 'Parameter.Value' --output text)",
            "DH_PASS=$(aws ssm get-parameter --name \"$PASS_PARAM\" --with-decryption --query 'Parameter.Value' --output text)",

            # create or patch
            "if kubectl -n \"$NS\" get secret \"$SECRET\" >/dev/null 2>&1; then",
            "  echo 'Secret exists; patching…'",
            "  kubectl -n \"$NS\" delete secret \"$SECRET\"",
            "fi",
            "kubectl -n \"$NS\" create secret docker-registry \"$SECRET\" \\",
            "  --docker-server=https://index.docker.io/v1/ \\",
            "  --docker-username=\"$DH_USER\" \\",
            "  --docker-password=\"$DH_PASS\""
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "create_dockerhub_secret_now" {
  for_each = toset(local.enabled_environments)

  name = aws_ssm_document.create_dockerhub_secret[each.key].name

  targets {
    key    = "tag:Environment"
    values = [each.key]
  }

  parameters = {
    Environment = each.key
    Namespace   = "default"
    SecretName  = "docker-hub-secret"
  }

  depends_on = [
    module.envs,
    aws_ssm_document.create_dockerhub_secret,
    aws_ssm_association.install_argocd_now,
    aws_ssm_association.argocd_wireup_now
  ]
}
