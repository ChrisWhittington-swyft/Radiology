############################################
# IAM Policies for AI Services
############################################
# Attaches Textract and Bedrock permissions to EKS node role
# Following the same pattern as Kafka (kafka.tf)

############################################
# Textract Policy
############################################

data "aws_iam_policy_document" "textract" {
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

resource "aws_iam_policy" "textract" {
  name        = "${local.name_prefix}-textract"
  description = "Policy for EKS nodes to access Amazon Textract"
  policy      = data.aws_iam_policy_document.textract.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "eks_nodes_textract" {
  role       = module.eks.eks_managed_node_groups["${local.name_prefix}-nodes"].iam_role_name
  policy_arn = aws_iam_policy.textract.arn
}

############################################
# Bedrock Policy
############################################

data "aws_iam_policy_document" "bedrock" {
  statement {
    sid    = "BedrockModelAccess"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:GetFoundationModel",
      "bedrock:ListFoundationModels"
    ]
    resources = [
      "arn:aws:bedrock:*:*:foundation-model/*",
      "arn:aws:bedrock:*:*:inference-profile/*"
    ]
  }

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

resource "aws_iam_policy" "bedrock" {
  name        = "${local.name_prefix}-bedrock"
  description = "Policy for EKS nodes to access Amazon Bedrock"
  policy      = data.aws_iam_policy_document.bedrock.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "eks_nodes_bedrock" {
  role       = module.eks.eks_managed_node_groups["${local.name_prefix}-nodes"].iam_role_name
  policy_arn = aws_iam_policy.bedrock.arn
}
