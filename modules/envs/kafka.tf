# ============================================
# modules/envs/kafka.tf
# Amazon MSK Serverless (Kafka)
# ============================================

locals {
  kafka_enabled = try(var.env_config[var.env_name].kafka.enabled, false)
  kafka_config = try(var.env_config[var.env_name].kafka, {
    enabled = false
  })
}

############################################
# Security Group for MSK
############################################

resource "aws_security_group" "kafka" {
  count       = local.kafka_enabled ? 1 : 0
  name        = "${local.name_prefix}-kafka"
  description = "Security group for MSK Serverless cluster"
  vpc_id      = var.vpc_id

  tags = merge(
    local.tags,
    {
      Name = "${local.name_prefix}-kafka"
    }
  )
}

resource "aws_vpc_security_group_ingress_rule" "kafka_from_eks" {
  count             = local.kafka_enabled ? 1 : 0
  security_group_id = aws_security_group.kafka[0].id
  description       = "Kafka from EKS nodes"

  from_port                    = 9098
  to_port                      = 9098
  ip_protocol                  = "tcp"
  referenced_security_group_id = local.eks_node_sg_id
}

resource "aws_vpc_security_group_ingress_rule" "kafka_from_bastion" {
  count             = local.kafka_enabled && var.enable_bastion ? 1 : 0
  security_group_id = aws_security_group.kafka[0].id
  description       = "Kafka from bastion"

  from_port                    = 9098
  to_port                      = 9098
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion[0].id
}

resource "aws_vpc_security_group_egress_rule" "kafka_all_outbound" {
  count             = local.kafka_enabled ? 1 : 0
  security_group_id = aws_security_group.kafka[0].id
  description       = "Allow all outbound"

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}

############################################
# CloudWatch Log Group for MSK
############################################

resource "aws_cloudwatch_log_group" "kafka" {
  count             = local.kafka_enabled ? 1 : 0
  name              = "/aws/msk/${local.name_prefix}"
  retention_in_days = 7

  tags = merge(
    local.tags,
    {
      Name = "${local.name_prefix}-kafka-logs"
    }
  )
}

############################################
# MSK Serverless Cluster
############################################

resource "aws_msk_serverless_cluster" "main" {
  count = local.kafka_enabled ? 1 : 0

  cluster_name = "${local.name_prefix}-kafka"

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.kafka[0].id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = merge(
    local.tags,
    {
      Name = "${local.name_prefix}-kafka"
    }
  )
}

############################################
# IAM Policy for MSK Access
############################################

data "aws_iam_policy_document" "kafka_client" {
  count = local.kafka_enabled ? 1 : 0

  statement {
    sid    = "MSKConnect"
    effect = "Allow"
    actions = [
      "kafka-cluster:Connect"
    ]
    resources = [aws_msk_serverless_cluster.main[0].arn]
  }

  statement {
    sid    = "MSKReadWrite"
    effect = "Allow"
    actions = [
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:CreateTopic",
      "kafka-cluster:WriteData",
      "kafka-cluster:ReadData"
    ]
    resources = [
      "${aws_msk_serverless_cluster.main[0].arn}/*"
    ]
  }

  statement {
    sid    = "MSKGroups"
    effect = "Allow"
    actions = [
      "kafka-cluster:AlterGroup",
      "kafka-cluster:DescribeGroup"
    ]
    resources = [
      "${aws_msk_serverless_cluster.main[0].arn}/*"
    ]
  }
}

resource "aws_iam_policy" "kafka_client" {
  count       = local.kafka_enabled ? 1 : 0
  name        = "${local.name_prefix}-kafka-client"
  description = "Policy for applications to access MSK Serverless"
  policy      = data.aws_iam_policy_document.kafka_client[0].json

  tags = local.tags
}

############################################
# Attach Kafka policy to EKS node role
############################################

resource "aws_iam_role_policy_attachment" "eks_nodes_kafka" {
  count      = local.kafka_enabled ? 1 : 0
  role       = module.eks.eks_managed_node_groups["${local.name_prefix}-nodes"].iam_role_name
  policy_arn = aws_iam_policy.kafka_client[0].arn
}

############################################
# SSM Parameters for Kafka Configuration
############################################

resource "aws_ssm_parameter" "kafka_bootstrap_servers" {
  count = local.kafka_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/kafka/bootstrap_servers"
  type  = "String"
  value = aws_msk_serverless_cluster.main[0].bootstrap_brokers_sasl_iam

  tags = merge(
    local.tags,
    {
      Name = "${local.name_prefix}-kafka-bootstrap-servers"
    }
  )
}

resource "aws_ssm_parameter" "kafka_cluster_arn" {
  count = local.kafka_enabled ? 1 : 0
  name  = "/eks/${module.eks.cluster_name}/kafka/cluster_arn"
  type  = "String"
  value = aws_msk_serverless_cluster.main[0].arn

  tags = merge(
    local.tags,
    {
      Name = "${local.name_prefix}-kafka-cluster-arn"
    }
  )
}
