resource "aws_ssm_document" "create_dockerhub_secret" {
  name          = "create-dockerhub-secret"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Create or update docker-hub secret in the default namespace",
    parameters = {
      Region      = { type = "String", default = local.effective_region }
      ClusterName = { type = "String", default = module.envs[local.primary_env].eks_cluster_name }
      UserParam   = { type = "String", default = "/bootstrap/dockerhub_user" }
      PassParam   = { type = "String", default = "/bootstrap/dockerhub_pass" }
      Namespace   = { type = "String", default = "default" }
      SecretName  = { type = "String", default = "docker-hub-secret" }
    },
    mainSteps = [
      {
        action = "aws:runShellScript",
        name   = "CreateDockerHubSecret",
        inputs = {
          runCommand = [
            "set -euo pipefail",
            "REGION='{{ Region }}'",
            "CLUSTER='{{ ClusterName }}'",
            "USER_PARAM='{{ UserParam }}'",
            "PASS_PARAM='{{ PassParam }}'",
            "NS='{{ Namespace }}'",
            "SECRET='{{ SecretName }}'",

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
  name = aws_ssm_document.create_dockerhub_secret.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = module.envs[local.primary_env].eks_cluster_name
    Namespace   = "default"
    SecretName  = "docker-hub-secret"
  }

  depends_on = [
    aws_ssm_association.install_argocd_now,  # cluster tools ready
    aws_ssm_association.argocd_wireup_now    # repo registered (optional order)
  ]
}
