module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.6.1"

  name               = "${local.name_prefix}-eks"
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

addons = {
    coredns                = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy             = {}
    vpc-cni                = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
      resolve_conflicts = "OVERWRITE"
  }
}


# Give the caller admin perms (optional; depends on how you manage access)
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    "${local.name_prefix}-nodes" = {
      instance_types = var.instance_types
      capacity_type  = var.capacity_type

      min_size     = var.min_size
      max_size     = var.max_size
      desired_size = var.desired_size

      labels = { env = var.env_name }
      tags   = local.tags
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = "${local.name_prefix}-eks"
  }

  tags = local.tags
}