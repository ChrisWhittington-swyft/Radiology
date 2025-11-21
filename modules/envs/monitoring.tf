# ============================================
# modules/envs/monitoring.tf
# In-cluster monitoring IAM roles (Prometheus/Grafana deployed via ArgoCD)
# ============================================

locals {
  monitoring_enabled = try(var.env_config[var.env_name].monitoring.enabled, true)
  monitoring_tags = merge(local.tags, {
    Component = "Monitoring"
    Project   = "EKS-Monitoring"
  })
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
      "kafka:ListClusters",
      "kafka:ListClustersV2",
      "kafka:DescribeCluster",
      "kafka:DescribeClusterV2",
      "kafka:ListTagsForResource",
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

