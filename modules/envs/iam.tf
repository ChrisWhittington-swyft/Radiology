# -----------------------------
# EKS Add-on
# -----------------------------

locals {
  eks_oidc_provider_host = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}

# Trust policy: allow only the EBS CSI controller SA in kube-system to assume this role
data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    sid     = "IRSAWebIdentity"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    # Require the exact SA identity
    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    # (Good practice) audience must be sts.amazonaws.com
    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name_prefix}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
  tags               = local.tags
}

# Attach the AWS-managed policy that the driver needs
resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}


# -----------------------------
# Bastion
# -----------------------------

# IAM for Bastion SSM

resource "aws_iam_role" "bastion_ssm" {
  count              = var.enable_bastion ? 1 : 0
  name               = "${local.name_prefix}-bastion-ssm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action   = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "bastion_ps_write" {
  count = var.enable_bastion ? 1 : 0
  name  = "${local.name_prefix}-bastion-ps-write"
  role  = aws_iam_role.bastion_ssm[0].id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["ssm:PutParameter"],
        Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/eks/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "bastion_grafana" {
  count = var.enable_bastion ? 1 : 0
  name  = "${local.name_prefix}-bastion-grafana"
  role  = aws_iam_role.bastion_ssm[0].id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "grafana:CreateWorkspaceApiKey",
          "grafana:DeleteWorkspaceApiKey",
          "grafana:DescribeWorkspace",
          "grafana:ListWorkspaces",
          "grafana:UpdateWorkspace",
          "grafana:CreateWorkspaceServiceAccount",
          "grafana:CreateWorkspaceServiceAccountToken"
        ],
        Resource = "arn:aws:grafana:${var.region}:${var.account_id}:/workspaces/*"
      },
      {
        Effect = "Allow",
        Action = [
          "aps:DescribeWorkspace",
          "aps:GetMetricMetadata",
          "aps:ListWorkspaces",
          "aps:QueryMetrics"
        ],
        Resource = "*"
      }
    ]
  })
}


resource "aws_iam_role_policy_attachment" "bastion_ssm_core" {
  count      = var.enable_bastion ? 1 : 0
  role       = aws_iam_role.bastion_ssm[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.enable_bastion ? 1 : 0
  name  = "${local.name_prefix}-bastion"
  role  = aws_iam_role.bastion_ssm[0].name
}

# IAM for Bastion EKS

# Create the access entry for the bastion role (no kubernetes_groups)
resource "aws_eks_access_entry" "bastion" {
  count         = var.enable_bastion ? 1 : 0
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.bastion_ssm[0].arn
  # Optionally set a username if you want (shown in kubectl whoami extensions):
  # username = "${local.name_prefix}-bastion"
}

# Attach cluster-admin via the managed policy
resource "aws_eks_access_policy_association" "bastion_admin" {
  count         = var.enable_bastion ? 1 : 0
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.bastion_ssm[0].arn

  access_scope {
    type = "cluster"
  }

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  depends_on = [aws_eks_access_entry.bastion]
}

resource "aws_iam_role_policy" "bastion_eks_discovery" {
  count = var.enable_bastion ? 1 : 0
  name  = "${local.name_prefix}-bastion-eks-discovery"
  role  = aws_iam_role.bastion_ssm[0].id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "eks:DescribeCluster",
          "eks:DescribeAddon",
          "eks:ListAddons",
          "eks:DescribeAddonVersions",
          "eks:DescribeAddonConfiguration"
        ],
        Resource = module.eks.cluster_arn
      },
      {
        Effect   = "Allow",
        Action   = ["eks:ListClusters"],
        Resource = "*"
      }
    ]
  })
}



data "aws_iam_policy_document" "bastion_secret_read" {
  # Secrets Manager (DB master secret created inside this module)
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db_master.arn]
  }

  # SSM Parameter Store (backend access keys)
  statement {
    actions = ["ssm:GetParameter", "ssm:GetParameters"]

    # If ARNs are passed from root, use them; otherwise fall back to a path pattern
    resources = (
      var.backend_access_key_param_arn != null && var.backend_secret_key_param_arn != null
    ) ? [
      var.backend_access_key_param_arn,
      var.backend_secret_key_param_arn
    ] : [
      "arn:aws:ssm:${var.region}:${var.account_id}:parameter/bootstrap/backend/*"
    ]
  }
}

resource "aws_iam_policy" "bastion_secret_read" {
  name   = "${local.name_prefix}-bastion-secret-read"
  policy = data.aws_iam_policy_document.bastion_secret_read.json
}


resource "aws_iam_role_policy_attachment" "bastion_secret_read" {
  role       = aws_iam_role.bastion_ssm[0].id
  policy_arn = aws_iam_policy.bastion_secret_read.arn
}



# IAM EKS SSO Access

resource "aws_eks_access_entry" "sso_admin" {
  count         = var.sso_admin_role_arn == null ? 0 : 1
  cluster_name  = module.eks.cluster_name
  principal_arn = var.sso_admin_role_arn
  # (Optional) username = "${local.name_prefix}-sso-admin"
}

resource "aws_eks_access_policy_association" "sso_admin_cluster_admin" {
  count         = var.sso_admin_role_arn == null ? 0 : 1
  cluster_name  = module.eks.cluster_name
  principal_arn = var.sso_admin_role_arn

  access_scope { type = "cluster" }
  policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  depends_on = [aws_eks_access_entry.sso_admin]
}


# Bastion permissions For EKS Add-on 

# Read EKS add-on state from the bastion
data "aws_iam_policy_document" "bastion_eks_addon_read" {
  statement {
    sid     = "ListAddonsOnCluster"
    effect  = "Allow"
    actions = [
      "eks:ListAddons",
    ]
    # ListAddons authorizes on the cluster resource
    resources = [
      module.eks.cluster_arn
    ]
  }

  statement {
    sid     = "DescribeAddonAndVersions"
    effect  = "Allow"
    actions = [
      "eks:DescribeAddon",
      "eks:DescribeAddonVersions",
      "eks:DescribeAddonConfiguration"
    ]
    # DescribeAddon authorizes on the ADDON resource
    resources = [
      "arn:aws:eks:${var.region}:${var.account_id}:addon/${module.eks.cluster_name}/*"
    ]
  }
}

resource "aws_iam_policy" "bastion_eks_addon_read" {
  name   = "${local.name_prefix}-bastion-eks-addon-read"
  policy = data.aws_iam_policy_document.bastion_eks_addon_read.json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "bastion_eks_addon_read" {
  role       = aws_iam_role.bastion_ssm[0].name
  policy_arn = aws_iam_policy.bastion_eks_addon_read.arn
}
