# ============================================
# modules/envs/karpenter.tf
# Karpenter infrastructure resources
# ============================================

locals {
  karpenter_enabled = try(var.env_config[var.env_name].karpenter.enabled, false)
  karpenter_config  = try(var.env_config[var.env_name].karpenter, {})
}

# ============================================
# Karpenter Controller IAM Role (IRSA)
# ============================================

data "aws_iam_policy_document" "karpenter_controller_trust" {
  count = local.karpenter_enabled ? 1 : 0

  statement {
    sid     = "KarpenterControllerAssumeRole"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  count              = local.karpenter_enabled ? 1 : 0
  name               = "${local.name_prefix}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_trust[0].json
  tags               = local.tags
}

data "aws_iam_policy_document" "karpenter_controller" {
  count = local.karpenter_enabled ? 1 : 0

  # EC2 permissions
  statement {
    sid = "KarpenterEC2"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateLaunchTemplateVersion",
      "ec2:CreateTags",
      "ec2:DeleteLaunchTemplate",
      "ec2:DeleteLaunchTemplateVersion",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:RunInstances",
      "ec2:TerminateInstances"
    ]
    resources = ["*"]
  }

  # SSM for AL2023 AMI discovery
  statement {
    sid = "KarpenterSSM"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/aws/service/*"]
  }

  # IAM for Spot service-linked role creation
  statement {
    sid = "KarpenterSpotServiceLinkedRole"
    actions = [
      "iam:CreateServiceLinkedRole"
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["spot.amazonaws.com"]
    }
  }

  # IAM PassRole for instance profile
  statement {
    sid = "KarpenterIAMPassRole"
    actions = [
      "iam:PassRole"
    ]
    resources = [aws_iam_role.karpenter_node[0].arn]
  }

  # EKS cluster describe
  statement {
    sid = "KarpenterEKS"
    actions = [
      "eks:DescribeCluster"
    ]
    resources = [module.eks.cluster_arn]
  }

  # SQS for spot interruption handling
  statement {
    sid = "KarpenterSQS"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage"
    ]
    resources = [aws_sqs_queue.karpenter[0].arn]
  }

  # Pricing API
  statement {
    sid = "KarpenterPricing"
    actions = [
      "pricing:GetProducts"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  count  = local.karpenter_enabled ? 1 : 0
  name   = "${local.name_prefix}-karpenter-controller"
  policy = data.aws_iam_policy_document.karpenter_controller[0].json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  count      = local.karpenter_enabled ? 1 : 0
  role       = aws_iam_role.karpenter_controller[0].name
  policy_arn = aws_iam_policy.karpenter_controller[0].arn
}

# ============================================
# Karpenter Node IAM Role (for EC2 instances)
# ============================================

data "aws_iam_policy_document" "karpenter_node_trust" {
  count = local.karpenter_enabled ? 1 : 0

  statement {
    sid     = "KarpenterNodeAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  count              = local.karpenter_enabled ? 1 : 0
  name               = "${local.name_prefix}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_trust[0].json
  tags               = local.tags
}

# Attach standard EKS node policies
resource "aws_iam_role_policy_attachment" "karpenter_node_eks_worker" {
  count      = local.karpenter_enabled ? 1 : 0
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  count      = local.karpenter_enabled ? 1 : 0
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  count      = local.karpenter_enabled ? 1 : 0
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  count      = local.karpenter_enabled ? 1 : 0
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile for Karpenter nodes
resource "aws_iam_instance_profile" "karpenter_node" {
  count = local.karpenter_enabled ? 1 : 0
  name  = "${local.name_prefix}-karpenter-node"
  role  = aws_iam_role.karpenter_node[0].name
  tags  = local.tags
}

# ============================================
# SQS Queue for Spot Interruption Handling
# ============================================

resource "aws_sqs_queue" "karpenter" {
  count                     = local.karpenter_enabled ? 1 : 0
  name                      = "${local.name_prefix}-${try(local.karpenter_config.interruption_queue_name, "karpenter")}"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

data "aws_iam_policy_document" "karpenter_queue" {
  count = local.karpenter_enabled ? 1 : 0

  statement {
    sid     = "EC2InterruptionPolicy"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }

    resources = [aws_sqs_queue.karpenter[0].arn]
  }
}

resource "aws_sqs_queue_policy" "karpenter" {
  count     = local.karpenter_enabled ? 1 : 0
  queue_url = aws_sqs_queue.karpenter[0].url
  policy    = data.aws_iam_policy_document.karpenter_queue[0].json
}

# ============================================
# EventBridge Rules for Spot Interruptions
# ============================================

# EC2 Spot Instance Interruption Warning
resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  count       = local.karpenter_enabled ? 1 : 0
  name        = "${local.name_prefix}-karpenter-spot-interruption"
  description = "Karpenter spot instance interruption warning"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  count = local.karpenter_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.karpenter_spot_interruption[0].name
  arn   = aws_sqs_queue.karpenter[0].arn
}

# EC2 Instance Rebalance Recommendation
resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  count       = local.karpenter_enabled ? 1 : 0
  name        = "${local.name_prefix}-karpenter-rebalance"
  description = "Karpenter EC2 rebalance recommendation"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  count = local.karpenter_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.karpenter_rebalance[0].name
  arn   = aws_sqs_queue.karpenter[0].arn
}

# EC2 Instance State Change (termination)
resource "aws_cloudwatch_event_rule" "karpenter_instance_state_change" {
  count       = local.karpenter_enabled ? 1 : 0
  name        = "${local.name_prefix}-karpenter-instance-state-change"
  description = "Karpenter EC2 instance state change"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "karpenter_instance_state_change" {
  count = local.karpenter_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.karpenter_instance_state_change[0].name
  arn   = aws_sqs_queue.karpenter[0].arn
}

# ============================================
# Subnet and Security Group Tags for Karpenter Discovery
# ============================================

resource "aws_ec2_tag" "karpenter_private_subnets" {
  for_each    = local.karpenter_enabled ? toset(var.private_subnet_ids) : []
  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = module.eks.cluster_name
}

resource "aws_ec2_tag" "karpenter_node_sg" {
  count       = local.karpenter_enabled ? 1 : 0
  resource_id = module.eks.node_security_group_id
  key         = "karpenter.sh/discovery"
  value       = module.eks.cluster_name
}

# ============================================
# SSM Parameters for Karpenter Configuration
# ============================================

resource "aws_ssm_parameter" "karpenter_cluster_name" {
  count = local.karpenter_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/karpenter/cluster_name"
  type  = "String"
  value = module.eks.cluster_name
  tags  = local.tags
}

resource "aws_ssm_parameter" "karpenter_cluster_endpoint" {
  count = local.karpenter_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/karpenter/cluster_endpoint"
  type  = "String"
  value = module.eks.cluster_endpoint
  tags  = local.tags
}

resource "aws_ssm_parameter" "karpenter_controller_role_arn" {
  count = local.karpenter_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/karpenter/controller_role_arn"
  type  = "String"
  value = aws_iam_role.karpenter_controller[0].arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "karpenter_node_instance_profile" {
  count = local.karpenter_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/karpenter/node_instance_profile"
  type  = "String"
  value = aws_iam_instance_profile.karpenter_node[0].name
  tags  = local.tags
}

resource "aws_ssm_parameter" "karpenter_queue_name" {
  count = local.karpenter_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/karpenter/queue_name"
  type  = "String"
  value = aws_sqs_queue.karpenter[0].name
  tags  = local.tags
}


# Allow Karpenter-managed EC2 nodes to join the cluster via EKS CAM
resource "aws_eks_access_entry" "karpenter_nodes" {
  count = local.karpenter_enabled ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.karpenter_node[0].arn

  # This tells EKS "this is an EC2 Linux node role" and it auto-wires the correct node identity/groups
  type = "EC2_LINUX"

  tags = local.tags

  depends_on = [
    aws_iam_role.karpenter_node,
    module.eks,
  ]
}
