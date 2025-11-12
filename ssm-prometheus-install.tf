############################################
# SSM Document: Install Prometheus in EKS
############################################

resource "aws_ssm_document" "install_prometheus" {
  count         = local.karpenter_enabled ? 1 : 0
  name          = "${lower(local.effective_tenant)}-${local.primary_env}-install-prometheus"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Prometheus and configure remote write to Amazon Managed Prometheus"

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
        name   = "InstallPrometheus"
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

            "echo \"[Prometheus] Starting installation...\"",

            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",
            "kubectl get ns kube-system 1>/dev/null 2>&1 || { echo \"[Prometheus] ERROR: cannot reach cluster\"; exit 1; }",

            "BASE_SSM_PATH=\"/eks/$CLUSTER_NAME/monitoring\"",
            "AMP_WORKSPACE_ID=$(aws ssm get-parameter --name \"$BASE_SSM_PATH/amp_workspace_id\" --query \"Parameter.Value\" --output text || true)",
            "AMP_INGESTION_ROLE_ARN=$(aws ssm get-parameter --name \"$BASE_SSM_PATH/amp_ingestion_role_arn\" --query \"Parameter.Value\" --output text || true)",

            "if [ -z \"$AMP_WORKSPACE_ID\" ] || [ -z \"$AMP_INGESTION_ROLE_ARN\" ]; then",
            "  echo \"[Prometheus] ERROR: Missing monitoring SSM parameters\"",
            "  echo \"  amp_workspace_id: $AMP_WORKSPACE_ID\"",
            "  echo \"  amp_ingestion_role_arn: $AMP_INGESTION_ROLE_ARN\"",
            "  exit 1",
            "fi",

            "AMP_ENDPOINT=\"https://aps-workspaces.$REGION.amazonaws.com/workspaces/$AMP_WORKSPACE_ID\"",
            "echo \"[Prometheus] AMP Workspace: $AMP_WORKSPACE_ID\"",
            "echo \"[Prometheus] AMP Endpoint: $AMP_ENDPOINT\"",
            "echo \"[Prometheus] Ingestion Role: $AMP_INGESTION_ROLE_ARN\"",

            "echo \"[Prometheus] Creating monitoring namespace\"",
            "kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -",

            "echo \"[Prometheus] Creating service account with IRSA\"",
            "cat <<SA_EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ServiceAccount",
            "metadata:",
            "  name: amp-collector",
            "  namespace: monitoring",
            "  annotations:",
            "    eks.amazonaws.com/role-arn: $AMP_INGESTION_ROLE_ARN",
            "SA_EOF",

            "echo \"[Prometheus] Installing kube-prometheus-stack via Helm\"",
            "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true",
            "helm repo update",

            "cat > /tmp/prometheus-values.yaml <<HELM_EOF",
            "prometheus:",
            "  serviceAccount:",
            "    create: false",
            "    name: amp-collector",
            "  prometheusSpec:",
            "    serviceAccountName: amp-collector",
            "    remoteWrite:",
            "    - url: $AMP_ENDPOINT/api/v1/remote_write",
            "      sigv4:",
            "        region: $REGION",
            "      queueConfig:",
            "        capacity: 10000",
            "        maxShards: 200",
            "        minShards: 1",
            "        maxSamplesPerSend: 1000",
            "        batchSendDeadline: 5s",
            "        minBackoff: 30ms",
            "        maxBackoff: 5s",
            "    retention: 6h",
            "    resources:",
            "      requests:",
            "        cpu: 500m",
            "        memory: 2Gi",
            "      limits:",
            "        cpu: 2000m",
            "        memory: 4Gi",
            "    storageSpec:",
            "      volumeClaimTemplate:",
            "        spec:",
            "          accessModes: ['ReadWriteOnce']",
            "          resources:",
            "            requests:",
            "              storage: 50Gi",
            "grafana:",
            "  enabled: false",
            "alertmanager:",
            "  enabled: true",
            "HELM_EOF",

            "helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \\",
            "  --namespace monitoring \\",
            "  --values /tmp/prometheus-values.yaml \\",
            "  --wait --timeout 10m",

            "echo \"[Prometheus] Installation complete\"",
            "kubectl -n monitoring get pods",
            "echo \"[Prometheus] Remote write configured to: $AMP_ENDPOINT\""
          ]
        }
      }
    ]
  })

  tags = {
    Tenant   = local.global_config.tenant_name
    Env      = local.primary_env
    Managed  = "Terraform"
    Project  = "EKS-Monitoring"
    Owner    = "Ops"
  }
}

resource "aws_ssm_association" "install_prometheus" {
  count = local.karpenter_enabled ? 1 : 0
  name  = aws_ssm_document.install_prometheus[0].name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = module.envs[local.primary_env].eks_cluster_name
  }

  depends_on = [
    module.envs,
    aws_ssm_association.install_karpenter_now
  ]
}
