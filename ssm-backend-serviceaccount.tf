############################################
# SSM Document: Create Backend Service Account
############################################

resource "aws_ssm_document" "backend_serviceaccount" {
  name          = "${lower(local.effective_tenant)}-${local.primary_env}-backend-serviceaccount"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Create/update backend-sa ServiceAccount with IRSA role annotation"

    parameters = {
      Region = {
        type    = "String"
        default = local.effective_region
      }
      ClusterName = {
        type    = "String"
        default = module.envs[local.primary_env].eks_cluster_name
      }
      RoleArn = {
        type    = "String"
        default = module.envs[local.primary_env].backend_irsa_role_arn
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "CreateServiceAccount"
        inputs = {
          runCommand = [
            "#!/bin/bash",
            "set -Eeuo pipefail",
            "exec 2>&1",

            "REGION='{{Region}}'",
            "CLUSTER_NAME='{{ClusterName}}'",
            "ROLE_ARN='{{RoleArn}}'",

            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",

            "echo \"[Backend SA] Configuring kubectl...\"",
            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",
            "kubectl get ns default 1>/dev/null 2>&1 || { echo \"[Backend SA] ERROR: cannot reach cluster\"; exit 1; }",

            "echo \"[Backend SA] Creating/updating ServiceAccount with IRSA role: $ROLE_ARN\"",

            # Create ServiceAccount with IRSA annotation
            "cat <<EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ServiceAccount",
            "metadata:",
            "  name: backend-sa",
            "  namespace: default",
            "  annotations:",
            "    eks.amazonaws.com/role-arn: $ROLE_ARN",
            "EOF",

            "echo \"[Backend SA] ServiceAccount created/updated successfully\"",
            "kubectl get serviceaccount backend-sa -n default -o yaml"
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "backend_serviceaccount_now" {
  name = aws_ssm_document.backend_serviceaccount.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = module.envs[local.primary_env].eks_cluster_name
    RoleArn     = module.envs[local.primary_env].backend_irsa_role_arn
  }

  depends_on = [
    aws_ssm_association.install_argocd_now,
  ]
}
