############################################
# SSM Document: Install External Secrets Operator
############################################

resource "aws_ssm_document" "install_external_secrets" {
  name          = "${lower(local.effective_tenant)}-${local.primary_env}-install-external-secrets"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install External Secrets Operator"

    parameters = {
      Region = {
        type    = "String"
        default = local.effective_region
      }
      ClusterName = {
        type    = "String"
        default = module.envs[local.primary_env].eks_cluster_name
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "InstallExternalSecrets"
        inputs = {
          timeoutSeconds = 600
          runCommand = [
            "#!/bin/bash",
            "set -Eeuo pipefail",
            "exec 2>&1",

            "REGION='{{Region}}'",
            "CLUSTER_NAME='{{ClusterName}}'",

            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",

            "echo \"[External Secrets] Starting installation...\"",

            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",
            "kubectl get ns kube-system 1>/dev/null 2>&1 || { echo \"[External Secrets] ERROR: cannot reach cluster\"; exit 1; }",

            # Install External Secrets Operator
            "echo \"[External Secrets] Installing External Secrets Operator...\"",
            "helm repo add external-secrets https://charts.external-secrets.io",
            "helm repo update",

            "helm upgrade --install external-secrets external-secrets/external-secrets \\",
            "  --namespace external-secrets-system \\",
            "  --create-namespace \\",
            "  --set installCRDs=true \\",
            "  --wait",

            "echo \"[External Secrets] Waiting for operator to be ready...\"",
            "kubectl -n external-secrets-system wait --for=condition=Ready pod -l app.kubernetes.io/name=external-secrets --timeout=120s",

            "echo \"[External Secrets] Installation complete!\"",
            "kubectl get pods -n external-secrets-system"
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "install_external_secrets_now" {
  name = aws_ssm_document.install_external_secrets.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = module.envs[local.primary_env].eks_cluster_name
  }

  depends_on = [
    aws_ssm_association.install_argocd_now,
  ]
}
