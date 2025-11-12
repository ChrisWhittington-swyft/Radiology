############################################
# AWS Monitoring: Prometheus + Grafana
############################################

locals {
  monitoring_enabled = true
  monitoring_tags = {
    Component = "Monitoring"
    ManagedBy = "Terraform"
    Project   = "EKS-Monitoring"
  }
  eks_oidc_provider_arn  = module.envs[local.primary_env].cluster_oidc_issuer_arn
  eks_oidc_provider_host = replace(module.envs[local.primary_env].cluster_oidc_issuer_url, "https://", "")
}

############################################
# Amazon Managed Service for Prometheus (AMP)
############################################

resource "aws_prometheus_workspace" "main" {
  count = local.monitoring_enabled ? 1 : 0
  alias = "${lower(local.effective_tenant)}-${local.primary_env}-prometheus"

  tags = merge(
    local.monitoring_tags,
    {
      Name = "${lower(local.effective_tenant)}-${local.primary_env}-prometheus"
      Env  = local.primary_env
    }
  )
}

resource "aws_ssm_parameter" "amp_workspace_id" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/monitoring/${local.primary_env}/amp_workspace_id"
  type  = "String"
  value = aws_prometheus_workspace.main[0].id
  tags  = local.monitoring_tags
}

resource "aws_ssm_parameter" "amp_workspace_arn" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/monitoring/${local.primary_env}/amp_workspace_arn"
  type  = "String"
  value = aws_prometheus_workspace.main[0].arn
  tags  = local.monitoring_tags
}

############################################
# IAM Role for Prometheus (ADOT/Collector)
############################################

data "aws_iam_policy_document" "amp_ingestion_trust" {
  count = local.monitoring_enabled ? 1 : 0

  statement {
    sid     = "AMPIngestOIDC"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:sub"
      values   = ["system:serviceaccount:monitoring:amp-collector"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "amp_ingestion_policy" {
  count = local.monitoring_enabled ? 1 : 0

  statement {
    sid    = "AMPWrite"
    effect = "Allow"
    actions = [
      "aps:RemoteWrite"
    ]
    resources = [aws_prometheus_workspace.main[0].arn]
  }

  statement {
    sid    = "AMPQuery"
    effect = "Allow"
    actions = [
      "aps:GetLabels",
      "aps:GetMetricMetadata",
      "aps:GetSeries",
      "aps:QueryMetrics"
    ]
    resources = [aws_prometheus_workspace.main[0].arn]
  }
}

resource "aws_iam_role" "amp_ingestion" {
  count              = local.monitoring_enabled ? 1 : 0
  name               = "${lower(local.effective_tenant)}-${local.primary_env}-amp-ingestion"
  assume_role_policy = data.aws_iam_policy_document.amp_ingestion_trust[0].json
  tags               = local.monitoring_tags
}

resource "aws_iam_role_policy" "amp_ingestion" {
  count  = local.monitoring_enabled ? 1 : 0
  name   = "${lower(local.effective_tenant)}-${local.primary_env}-amp-ingestion"
  role   = aws_iam_role.amp_ingestion[0].id
  policy = data.aws_iam_policy_document.amp_ingestion_policy[0].json
}

resource "aws_ssm_parameter" "amp_ingestion_role_arn" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/monitoring/${local.primary_env}/amp_ingestion_role_arn"
  type  = "String"
  value = aws_iam_role.amp_ingestion[0].arn
  tags  = local.monitoring_tags
}

############################################
# Amazon Managed Grafana (AMG)
############################################

resource "aws_grafana_workspace" "main" {
  count = local.monitoring_enabled ? 1 : 0

  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana[0].arn
  name                     = "${lower(local.effective_tenant)}-${local.primary_env}-monitoring"

  tags = merge(
    local.monitoring_tags,
    {
      Name = "${lower(local.effective_tenant)}-${local.primary_env}-grafana"
      Env  = local.primary_env
    }
  )
}

resource "aws_ssm_parameter" "grafana_workspace_id" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/monitoring/${local.primary_env}/grafana_workspace_id"
  type  = "String"
  value = aws_grafana_workspace.main[0].id
  tags  = local.monitoring_tags
}

resource "aws_ssm_parameter" "grafana_workspace_url" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/monitoring/${local.primary_env}/grafana_workspace_url"
  type  = "String"
  value = aws_grafana_workspace.main[0].endpoint
  tags  = local.monitoring_tags
}

############################################
# IAM Role for Grafana
############################################

data "aws_iam_policy_document" "grafana_assume_role" {
  count = local.monitoring_enabled ? 1 : 0

  statement {
    sid    = "GrafanaAssumeRole"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "grafana_permissions" {
  count = local.monitoring_enabled ? 1 : 0

  statement {
    sid    = "AMGReadAMP"
    effect = "Allow"
    actions = [
      "aps:GetLabels",
      "aps:GetMetricMetadata",
      "aps:GetSeries",
      "aps:QueryMetrics",
      "aps:ListWorkspaces",
      "aps:DescribeWorkspace"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AMGReadCloudWatch"
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:GetMetricData"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AMGReadLogs"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AMGReadEC2"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "ec2:DescribeRegions"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AMGReadRDS"
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
      "rds:DescribeDBClusters",
      "rds:ListTagsForResource"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "grafana" {
  count              = local.monitoring_enabled ? 1 : 0
  name               = "${lower(local.effective_tenant)}-${local.primary_env}-grafana"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume_role[0].json
  tags               = local.monitoring_tags
}

resource "aws_iam_role_policy" "grafana" {
  count  = local.monitoring_enabled ? 1 : 0
  name   = "${lower(local.effective_tenant)}-${local.primary_env}-grafana"
  role   = aws_iam_role.grafana[0].id
  policy = data.aws_iam_policy_document.grafana_permissions[0].json
}

############################################
# Grafana Data Source: Prometheus
############################################

resource "aws_grafana_workspace_api_key" "main" {
  count            = local.monitoring_enabled ? 1 : 0
  key_name         = "terraform-provisioning"
  key_role         = "ADMIN"
  seconds_to_live  = 3600
  workspace_id     = aws_grafana_workspace.main[0].id
}

############################################
# CloudWatch Log Group for Monitoring
############################################

resource "aws_cloudwatch_log_group" "monitoring" {
  count             = local.monitoring_enabled ? 1 : 0
  name              = "/aws/eks/${local.primary_env}/monitoring"
  retention_in_days = 7

  tags = merge(
    local.monitoring_tags,
    {
      Name = "${lower(local.effective_tenant)}-${local.primary_env}-monitoring-logs"
    }
  )
}

############################################
# SSM Document: Install Prometheus in EKS
############################################

resource "aws_ssm_document" "install_prometheus" {
  count         = local.monitoring_enabled ? 1 : 0
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
      AMPWorkspaceId = {
        type    = "String"
        default = try(aws_prometheus_workspace.main[0].id, "")
      }
      AMPIngestionRoleArn = {
        type    = "String"
        default = try(aws_iam_role.amp_ingestion[0].arn, "")
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
            "AMP_WORKSPACE_ID='{{AMPWorkspaceId}}'",
            "AMP_INGESTION_ROLE_ARN='{{AMPIngestionRoleArn}}'",

            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",

            "echo \"[Prometheus] Starting installation...\"",

            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",
            "kubectl get ns kube-system 1>/dev/null 2>&1 || { echo \"[Prometheus] ERROR: cannot reach cluster\"; exit 1; }",

            "echo \"[Prometheus] Creating monitoring namespace\"",
            "kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -",

            "echo \"[Prometheus] Creating service account with IRSA\"",
            "cat <<'SA_EOF' | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ServiceAccount",
            "metadata:",
            "  name: amp-collector",
            "  namespace: monitoring",
            "  annotations:",
            "    eks.amazonaws.com/role-arn: $AMP_INGESTION_ROLE_ARN",
            "SA_EOF",

            "echo \"[Prometheus] Installing kube-prometheus-stack via Helm\"",
            "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts",
            "helm repo update",

            "AMP_ENDPOINT=\"https://aps-workspaces.$REGION.amazonaws.com/workspaces/$AMP_WORKSPACE_ID\"",

            "cat > /tmp/prometheus-values.yaml <<HELM_EOF",
            "prometheus:",
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
            "HELM_EOF",

            "helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \\",
            "  --namespace monitoring \\",
            "  --values /tmp/prometheus-values.yaml \\",
            "  --wait --timeout 10m",

            "echo \"[Prometheus] Installation complete\"",
            "kubectl -n monitoring get pods",
            "echo \"[Prometheus] Remote write configured to AMP: $AMP_ENDPOINT\""
          ]
        }
      }
    ]
  })

  tags = local.monitoring_tags
}

resource "aws_ssm_association" "install_prometheus" {
  count = local.monitoring_enabled ? 1 : 0
  name  = aws_ssm_document.install_prometheus[0].name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region              = local.effective_region
    ClusterName         = module.envs[local.primary_env].eks_cluster_name
    AMPWorkspaceId      = aws_prometheus_workspace.main[0].id
    AMPIngestionRoleArn = aws_iam_role.amp_ingestion[0].arn
  }

  depends_on = [
    aws_prometheus_workspace.main,
    aws_iam_role.amp_ingestion,
    module.envs
  ]
}

############################################
# Outputs
############################################

output "amp_workspace_id" {
  description = "Amazon Managed Prometheus workspace ID"
  value       = try(aws_prometheus_workspace.main[0].id, null)
}

output "amp_workspace_url" {
  description = "Amazon Managed Prometheus workspace URL"
  value       = try("https://aps-workspaces.${local.effective_region}.amazonaws.com/workspaces/${aws_prometheus_workspace.main[0].id}", null)
}

output "grafana_workspace_id" {
  description = "Amazon Managed Grafana workspace ID"
  value       = try(aws_grafana_workspace.main[0].id, null)
}

output "grafana_workspace_url" {
  description = "Amazon Managed Grafana workspace URL"
  value       = try(aws_grafana_workspace.main[0].endpoint, null)
}

output "monitoring_log_group" {
  description = "CloudWatch log group for monitoring"
  value       = try(aws_cloudwatch_log_group.monitoring[0].name, null)
}
