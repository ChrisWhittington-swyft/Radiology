# ============================================
# modules/envs/monitoring.tf
# Amazon Managed Prometheus + Grafana per environment
# ============================================

locals {
  monitoring_enabled = try(var.env_config[var.env_name].monitoring.enabled, true)
  monitoring_tags = merge(local.tags, {
    Component = "Monitoring"
    Project   = "EKS-Monitoring"
  })
}

############################################
# Amazon Managed Service for Prometheus (AMP)
############################################

resource "aws_prometheus_workspace" "main" {
  count = local.monitoring_enabled ? 1 : 0
  alias = "${local.name_prefix}-prometheus"

  tags = merge(
    local.monitoring_tags,
    {
      Name = "${local.name_prefix}-prometheus"
    }
  )
}

############################################
# IAM Role for Prometheus (IRSA)
############################################

data "aws_iam_policy_document" "amp_ingestion_trust" {
  count = local.monitoring_enabled ? 1 : 0

  statement {
    sid     = "AMPIngestOIDC"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
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
  name               = "${local.name_prefix}-amp-ingestion"
  assume_role_policy = data.aws_iam_policy_document.amp_ingestion_trust[0].json
  tags               = local.monitoring_tags
}

resource "aws_iam_role_policy" "amp_ingestion" {
  count  = local.monitoring_enabled ? 1 : 0
  name   = "${local.name_prefix}-amp-ingestion"
  role   = aws_iam_role.amp_ingestion[0].id
  policy = data.aws_iam_policy_document.amp_ingestion_policy[0].json
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
  name                     = "${local.name_prefix}-monitoring"

  tags = merge(
    local.monitoring_tags,
    {
      Name = "${local.name_prefix}-grafana"
    }
  )
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
  name               = "${local.name_prefix}-grafana"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume_role[0].json
  tags               = local.monitoring_tags
}

resource "aws_iam_role_policy" "grafana" {
  count  = local.monitoring_enabled ? 1 : 0
  name   = "${local.name_prefix}-grafana"
  role   = aws_iam_role.grafana[0].id
  policy = data.aws_iam_policy_document.grafana_permissions[0].json
}

############################################
# CloudWatch Log Group for Monitoring
############################################

resource "aws_cloudwatch_log_group" "monitoring" {
  count             = local.monitoring_enabled ? 1 : 0
  name              = "/aws/eks/${var.env_name}/monitoring"
  retention_in_days = 7

  tags = merge(
    local.monitoring_tags,
    {
      Name = "${local.name_prefix}-monitoring-logs"
    }
  )
}

############################################
# SSM Parameters for Monitoring Configuration
############################################

resource "aws_ssm_parameter" "amp_workspace_id" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/monitoring/amp_workspace_id"
  type  = "String"
  value = aws_prometheus_workspace.main[0].id
  tags  = local.monitoring_tags
}

resource "aws_ssm_parameter" "amp_workspace_arn" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/monitoring/amp_workspace_arn"
  type  = "String"
  value = aws_prometheus_workspace.main[0].arn
  tags  = local.monitoring_tags
}

resource "aws_ssm_parameter" "amp_ingestion_role_arn" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/monitoring/amp_ingestion_role_arn"
  type  = "String"
  value = aws_iam_role.amp_ingestion[0].arn
  tags  = local.monitoring_tags
}

resource "aws_ssm_parameter" "grafana_workspace_id" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/monitoring/grafana_workspace_id"
  type  = "String"
  value = aws_grafana_workspace.main[0].id
  tags  = local.monitoring_tags
}

resource "aws_ssm_parameter" "grafana_workspace_url" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/monitoring/grafana_workspace_url"
  type  = "String"
  value = aws_grafana_workspace.main[0].endpoint
  tags  = local.monitoring_tags
}

############################################
# IAM Role for YACE CloudWatch Exporter (IRSA)
############################################

data "aws_iam_policy_document" "yace_trust" {
  count = local.monitoring_enabled ? 1 : 0

  statement {
    sid     = "YACEExporterOIDC"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:sub"
      values   = ["system:serviceaccount:monitoring:yace-exporter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "yace_policy" {
  count = local.monitoring_enabled ? 1 : 0

  statement {
    sid    = "YACECloudWatchRead"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "YACEResourceDiscovery"
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
      "rds:DescribeDBClusters",
      "rds:ListTagsForResource",
      "tag:GetResources"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "yace" {
  count              = local.monitoring_enabled ? 1 : 0
  name               = "${local.name_prefix}-yace-exporter"
  assume_role_policy = data.aws_iam_policy_document.yace_trust[0].json
  tags               = local.monitoring_tags
}

resource "aws_iam_role_policy" "yace" {
  count  = local.monitoring_enabled ? 1 : 0
  name   = "${local.name_prefix}-yace-exporter"
  role   = aws_iam_role.yace[0].id
  policy = data.aws_iam_policy_document.yace_policy[0].json
}

resource "aws_ssm_parameter" "yace_role_arn" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/monitoring/yace_role_arn"
  type  = "String"
  value = aws_iam_role.yace[0].arn
  tags  = local.monitoring_tags
}

############################################
# IAM Role for AlertManager SNS Forwarder (IRSA)
############################################

data "aws_iam_policy_document" "sns_forwarder_trust" {
  count = local.monitoring_enabled ? 1 : 0

  statement {
    sid     = "SNSForwarderOIDC"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:sub"
      values   = ["system:serviceaccount:monitoring:alertmanager-sns-forwarder"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "sns_forwarder_policy" {
  count = local.monitoring_enabled ? 1 : 0

  statement {
    sid    = "SNSPublish"
    effect = "Allow"
    actions = [
      "sns:Publish"
    ]
    resources = [aws_sns_topic.account_alerts_topic.arn]
  }
}

resource "aws_iam_role" "sns_forwarder" {
  count              = local.monitoring_enabled ? 1 : 0
  name               = "${local.name_prefix}-alertmanager-sns-forwarder"
  assume_role_policy = data.aws_iam_policy_document.sns_forwarder_trust[0].json
  tags               = local.monitoring_tags
}

resource "aws_iam_role_policy" "sns_forwarder" {
  count  = local.monitoring_enabled ? 1 : 0
  name   = "${local.name_prefix}-alertmanager-sns-forwarder"
  role   = aws_iam_role.sns_forwarder[0].id
  policy = data.aws_iam_policy_document.sns_forwarder_policy[0].json
}

resource "aws_ssm_parameter" "sns_forwarder_role_arn" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/monitoring/sns_forwarder_role_arn"
  type  = "String"
  value = aws_iam_role.sns_forwarder[0].arn
  tags  = local.monitoring_tags
}

resource "aws_ssm_parameter" "sns_topic_arn" {
  count = local.monitoring_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/monitoring/sns_topic_arn"
  type  = "String"
  value = aws_sns_topic.account_alerts_topic.arn
  tags  = local.monitoring_tags
}

############################################
# Grafana Datasource Configuration
# Note: Datasource will be configured via SSM automation
# using the Grafana API, as Terraform AWS provider
# does not support Grafana datasource resources
#
# ADMIN ACCESS:
# To get admin permissions in Grafana, assign yourself via AWS Console:
# 1. Go to Amazon Managed Grafana console
# 2. Select your workspace
# 3. Go to "Authentication" tab → "AWS IAM Identity Center"
# 4. Click "Assign new user or group"
# 5. Select your SSO user and assign "Admin" role
############################################
