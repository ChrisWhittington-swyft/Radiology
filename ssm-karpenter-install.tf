############################################
# SSM Document: Install/Upgrade Karpenter
############################################

resource "aws_ssm_document" "install_karpenter" {
  name          = "install-karpenter"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install/upgrade Karpenter via Helm (OCI) using values from SSM - per environment"

    parameters = {
      Environment = {
        type        = "String"
        description = "Environment name (prod, dev, etc.)"
      }
      Namespace = {
        type    = "String"
        default = "karpenter"
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "InstallKarpenter"
        inputs = {
          timeoutSeconds = 900
          runCommand = [
            "#!/bin/bash",
            "set -Eeuo pipefail",

            "echo \"[Karpenter] Starting install/upgrade...\"",

            # -------------------------
            # Parameters & environment
            # -------------------------
            "ENV=\"{{Environment}}\"",
            "NS=\"{{Namespace}}\"",
            "echo \"[Karpenter] Starting for environment: $ENV\"",

            # Lookup environment-specific values from SSM
            "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
            "CLUSTER_NAME=$(aws ssm get-parameter --name /terraform/envs/$ENV/cluster_name --query 'Parameter.Value' --output text --region $REGION)",
            "KARPENTER_VERSION=$(aws ssm get-parameter --name /terraform/envs/$ENV/karpenter/version --query 'Parameter.Value' --output text --region $REGION)",

            "echo \"Configuration loaded for $ENV\"",
            "echo \"  Cluster: $CLUSTER_NAME\"",
            "echo \"  Version: $KARPENTER_VERSION\"",

            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\"",
            "export AWS_DEFAULT_REGION=\"$REGION\"",

            "echo \"[Karpenter] Using Region: $AWS_REGION, Cluster: $CLUSTER_NAME, Namespace: $NS, Version: $KARPENTER_VERSION\"",

            # -------------------------
            # AWS + EKS reachability
            # -------------------------
            "aws sts get-caller-identity 1>/dev/null",
            "aws eks describe-cluster --name \"$CLUSTER_NAME\" --region \"$AWS_REGION\" 1>/dev/null",

            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$AWS_REGION\" --kubeconfig \"$KUBECONFIG\"",

            "kubectl get ns kube-system 1>/dev/null 2>&1 || { echo \"[Karpenter] ERROR: cannot list namespaces; API unreachable\"; exit 1; }",

            # -------------------------
            # Read Karpenter config from SSM
            # (created by modules/envs/karpenter.tf)
            # -------------------------
            "BASE_SSM_PATH=\"/eks/$CLUSTER_NAME/karpenter\"",

            "CONTROLLER_ROLE_ARN=$(aws ssm get-parameter --name \"$BASE_SSM_PATH/controller_role_arn\" --query \"Parameter.Value\" --output text || true)",
            "NODE_INSTANCE_PROFILE=$(aws ssm get-parameter --name \"$BASE_SSM_PATH/node_instance_profile\" --query \"Parameter.Value\" --output text || true)",
            "QUEUE_NAME=$(aws ssm get-parameter --name \"$BASE_SSM_PATH/queue_name\" --query \"Parameter.Value\" --output text || true)",

            "if [ -z \"$CONTROLLER_ROLE_ARN\" ] || [ -z \"$NODE_INSTANCE_PROFILE\" ] || [ -z \"$QUEUE_NAME\" ]; then",
            "  echo \"[Karpenter] ERROR: Missing one or more required SSM parameters\"",
            "  echo \"  controller_role_arn: $CONTROLLER_ROLE_ARN\"",
            "  echo \"  node_instance_profile: $NODE_INSTANCE_PROFILE\"",
            "  echo \"  queue_name: $QUEUE_NAME\"",
            "  exit 1",
            "fi",

            "CLUSTER_ENDPOINT=$(aws eks describe-cluster --name \"$CLUSTER_NAME\" --region \"$AWS_REGION\" --query \"cluster.endpoint\" --output text)",

            "echo \"[Karpenter] ControllerRole: $CONTROLLER_ROLE_ARN\"",
            "echo \"[Karpenter] InstanceProfile: $NODE_INSTANCE_PROFILE\"",
            "echo \"[Karpenter] Queue: $QUEUE_NAME\"",
            "echo \"[Karpenter] Endpoint: $CLUSTER_ENDPOINT\"",

            # -------------------------
            # Helm + OCI auth
            # -------------------------
            "helm version || { echo \"[Karpenter] ERROR: helm not installed\"; exit 1; }",

            # Best-effort ECR Public login (ok to fail)
            "aws ecr-public get-login-password --region us-east-1 2>/dev/null | helm registry login public.ecr.aws --username AWS --password-stdin 2>/dev/null || true",

            # -------------------------
            # Install/Upgrade Karpenter (v1, OCI chart)
            # -------------------------
            "echo \"[Karpenter] Installing/Upgrading via OCI chart...\"",
            "helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \\",
            "  --version \"$${KARPENTER_VERSION}\" \\",
            "  --namespace \"$${NS}\" \\",
            "  --create-namespace \\",
            "  --set settings.clusterName=\"$${CLUSTER_NAME}\" \\",
            "  --set settings.clusterEndpoint=\"$${CLUSTER_ENDPOINT}\" \\",
            "  --set settings.interruptionQueue=\"$${QUEUE_NAME}\" \\",
            "  --set-string serviceAccount.annotations.'eks\\.amazonaws\\.com/role-arn'=\"$CONTROLLER_ROLE_ARN\" \\",
            "  --set settings.isolatedVPC=true \\",
            "  --wait",
            "echo \"[Karpenter] Installation complete.\""
          ]
        }
      }
    ]
  })
}


############################################
# Association: run on bastion
############################################

resource "aws_ssm_association" "install_karpenter_now" {
  for_each = {
    for k in local.enabled_environments : k => k
    if try(local.environments[k].karpenter.enabled, false)
  }

  name = aws_ssm_document.install_karpenter.name

  targets {
    key    = "tag:Environment"
    values = [each.key]
  }

  parameters = {
    Environment = each.key
    Namespace   = "karpenter"
  }

  depends_on = [
    module.envs,
    aws_ssm_document.install_karpenter,
    aws_ssm_parameter.env_cluster_names,
    aws_ssm_parameter.env_karpenter_version,
  ]
}
