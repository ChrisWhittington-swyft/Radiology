# -----------------------------
# Backend Application IRSA
# -----------------------------
# Allows backend pods to call AWS services (Textract, Bedrock, S3, etc)

# Trust policy for backend service account
data "aws_iam_policy_document" "backend_trust" {
  statement {
    sid     = "BackendIRSA"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    # Allow the backend-sa service account in default namespace
    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:sub"
      values   = ["system:serviceaccount:default:backend-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backend" {
  name               = "${local.name_prefix}-backend"
  assume_role_policy = data.aws_iam_policy_document.backend_trust.json
  tags               = local.tags
}

# Textract permissions
data "aws_iam_policy_document" "backend_textract" {
  statement {
    sid    = "TextractAccess"
    effect = "Allow"
    actions = [
      "textract:AnalyzeDocument",
      "textract:AnalyzeExpense",
      "textract:AnalyzeID",
      "textract:DetectDocumentText",
      "textract:StartDocumentAnalysis",
      "textract:StartDocumentTextDetection",
      "textract:StartExpenseAnalysis",
      "textract:GetDocumentAnalysis",
      "textract:GetDocumentTextDetection",
      "textract:GetExpenseAnalysis"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "backend_textract" {
  name   = "${local.name_prefix}-backend-textract"
  policy = data.aws_iam_policy_document.backend_textract.json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "backend_textract" {
  role       = aws_iam_role.backend.name
  policy_arn = aws_iam_policy.backend_textract.arn
}

# Bedrock permissions
data "aws_iam_policy_document" "backend_bedrock" {
  statement {
    sid    = "BedrockAccess"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:GetFoundationModel",
      "bedrock:ListFoundationModels"
    ]
    resources = [
      "arn:aws:bedrock:${var.region}::foundation-model/*"
    ]
  }

  # If using Agents or Knowledge Bases
  statement {
    sid    = "BedrockAgentsKB"
    effect = "Allow"
    actions = [
      "bedrock:InvokeAgent",
      "bedrock:Retrieve",
      "bedrock:RetrieveAndGenerate"
    ]
    resources = [
      "arn:aws:bedrock:${var.region}:${var.account_id}:agent/*",
      "arn:aws:bedrock:${var.region}:${var.account_id}:knowledge-base/*"
    ]
  }
}

resource "aws_iam_policy" "backend_bedrock" {
  name   = "${local.name_prefix}-backend-bedrock"
  policy = data.aws_iam_policy_document.backend_bedrock.json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "backend_bedrock" {
  role       = aws_iam_role.backend.name
  policy_arn = aws_iam_policy.backend_bedrock.arn
}

# S3 access (already have bucket name in backend config)
data "aws_iam_policy_document" "backend_s3" {
  statement {
    sid    = "S3BucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.backend_s3_bucket}",
      "arn:aws:s3:::${var.backend_s3_bucket}/*"
    ]
  }
}

resource "aws_iam_policy" "backend_s3" {
  name   = "${local.name_prefix}-backend-s3"
  policy = data.aws_iam_policy_document.backend_s3.json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "backend_s3" {
  role       = aws_iam_role.backend.name
  policy_arn = aws_iam_policy.backend_s3.arn
}

# MSK/Kafka access (if enabled)
data "aws_iam_policy_document" "backend_kafka" {
  count = local.kafka_enabled ? 1 : 0

  statement {
    sid    = "KafkaClusterAccess"
    effect = "Allow"
    actions = [
      "kafka-cluster:Connect",
      "kafka-cluster:DescribeCluster"
    ]
    resources = [
      aws_msk_serverless_cluster.main[0].arn
    ]
  }

  statement {
    sid    = "KafkaTopicAccess"
    effect = "Allow"
    actions = [
      "kafka-cluster:CreateTopic",
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:WriteData",
      "kafka-cluster:ReadData"
    ]
    resources = [
      "arn:aws:kafka:${var.region}:${var.account_id}:topic/${module.eks.cluster_name}/*/*"
    ]
  }

  statement {
    sid    = "KafkaGroupAccess"
    effect = "Allow"
    actions = [
      "kafka-cluster:AlterGroup",
      "kafka-cluster:DescribeGroup"
    ]
    resources = [
      "arn:aws:kafka:${var.region}:${var.account_id}:group/${module.eks.cluster_name}/*/*"
    ]
  }
}

resource "aws_iam_policy" "backend_kafka" {
  count  = local.kafka_enabled ? 1 : 0
  name   = "${local.name_prefix}-backend-kafka"
  policy = data.aws_iam_policy_document.backend_kafka[0].json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "backend_kafka" {
  count      = local.kafka_enabled ? 1 : 0
  role       = aws_iam_role.backend.name
  policy_arn = aws_iam_policy.backend_kafka[0].arn
}
