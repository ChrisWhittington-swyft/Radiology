############################################
# SSM Document: Install/Upgrade Karpenter
############################################

resource "aws_ssm_document" "install_karpenter" {
  count         = local.karpenter_enabled ? 1 : 0
  name          = "${lower(local.global_config.tenant_name)}-${local.primary_env}-install-karpenter"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install/upgrade Karpenter via Helm (OCI) using values from SSM; supports private EKS cluster."

    parameters = {
      Region = {
        type    = "String"
        default = local.global_config.region
      }
      ClusterName = {
        type    = "String"
        # Use the cluster for the selected primary_env
        default = module.envs[local.primary_env].eks_cluster_name
      }
      Namespace = {
        type    = "String"
        default = "karpenter"
      }
      Version = {
        type    = "String"
        default = local.karpenter_version
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
            "PARAM_REGION=\"{{Region}}\"",
            "CLUSTER_NAME=\"{{ClusterName}}\"",
            "NS=\"{{Namespace}}\"",
            "KARPENTER_VERSION=\"{{Version}}\"",

            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",

            # Detect region from IMDS if not provided
            "if [ -z \"$PARAM_REGION\" ] || [ \"$PARAM_REGION\" = \"null\" ]; then",
            "  echo \"[Karpenter] Region not provided, detecting from IMDS...\"",
            "  TOKEN=$(curl -sS -X PUT \"http://169.254.169.254/latest/api/token\" -H \"X-aws-ec2-metadata-token-ttl-seconds: 60\" || true)",
            "  if [ -n \"$TOKEN\" ]; then",
            "    PARAM_REGION=$(curl -sS -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/placement/region || true)",
            "  else",
            "    PARAM_REGION=$(curl -sS http://169.254.169.254/latest/meta-data/placement/region || true)",
            "  fi",
            "fi",

            "if [ -z \"$PARAM_REGION\" ]; then",
            "  echo \"[Karpenter] ERROR: Unable to determine AWS region\"",
            "  exit 1",
            "fi",

            "export AWS_REGION=\"$PARAM_REGION\"",
            "export AWS_DEFAULT_REGION=\"$PARAM_REGION\"",

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
            "  --set serviceMonitor.enabled=true \\",
            "  --set serviceMonitor.additionalLabels.release=prometheus \\",
            "  --wait",
            "echo \"[Karpenter] Installation complete with metrics enabled.\""
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
  count = local.karpenter_enabled ? 1 : 0
  name  = aws_ssm_document.install_karpenter[0].name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.global_config.tenant_name)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region      = local.global_config.region
    ClusterName = module.envs[local.primary_env].eks_cluster_name
    Namespace   = "karpenter"
    Version     = local.karpenter_version
  }

  depends_on = [
    module.envs
  ]
}
