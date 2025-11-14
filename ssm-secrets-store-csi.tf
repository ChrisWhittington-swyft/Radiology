############################################
# SSM Document: Install Secrets Store CSI Driver
############################################

resource "aws_ssm_document" "install_secrets_csi" {
  name          = "${lower(local.effective_tenant)}-${local.primary_env}-install-secrets-csi"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Secrets Store CSI Driver with AWS Provider"

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
        name   = "InstallSecretsCSI"
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

            "echo \"[Secrets CSI] Starting installation...\"",

            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",
            "kubectl get ns kube-system 1>/dev/null 2>&1 || { echo \"[Secrets CSI] ERROR: cannot reach cluster\"; exit 1; }",

            # Install Secrets Store CSI Driver
            "echo \"[Secrets CSI] Installing Secrets Store CSI Driver...\"",
            "helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts",
            "helm repo update",

            "helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \\",
            "  --namespace kube-system \\",
            "  --set syncSecret.enabled=true \\",
            "  --set enableSecretRotation=true \\",
            "  --wait",

            # Install AWS Provider
            "echo \"[Secrets CSI] Installing AWS Secrets & Configuration Provider...\"",
            "kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml",

            "echo \"[Secrets CSI] Waiting for AWS provider to be ready...\"",
            "kubectl -n kube-system wait --for=condition=Ready pod -l app=csi-secrets-store-provider-aws --timeout=120s",

            "echo \"[Secrets CSI] Installation complete!\"",
            "kubectl get pods -n kube-system -l app.kubernetes.io/name=secrets-store-csi-driver",
            "kubectl get pods -n kube-system -l app=csi-secrets-store-provider-aws"
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "install_secrets_csi_now" {
  name = aws_ssm_document.install_secrets_csi.name

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
