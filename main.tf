terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
  # PROVIDER CONFIGURATION
  # ----------------------

# Workload account
provider "aws" {
  region  = var.region
  profile = "Radiology"
}

# DATA SOURCES
# ------------

data "aws_region" "current" {}

# DNS account (aliased)
provider "aws" {
  alias   = "dns"
  region  = "us-east-1"
  profile = "Radiology"
}

# Providers into the cluster
provider "kubernetes" {
  alias                  = "prod"
  host                   = data.aws_eks_cluster.prod.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.prod.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.prod.token
}

provider "helm" {
  alias = "prod"
  kubernetes {
    host                   = data.aws_eks_cluster.prod.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.prod.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.prod.token
  }
}


  # MODULES
  # ----------------------

module "envs" {
  for_each             = { for k, v in local.environments : k => v if contains(local.enabled_environments, k) }
  source               = "./modules/envs"

  region               = local.global_config.region
# Env identity
  env_name             = each.key
  enabled_environments = local.enabled_environments
  sso_admin_role_arn   = local.global_config.sso_admin_role_arn

  # Networking
  vpc_id             = aws_vpc.terraform_vpc.id
  public_subnet_ids  = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
  private_subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
  extra_ingress      = lookup(each.value, "extra_ingress", {})

  # IAM
  backend_access_key_param_arn = aws_ssm_parameter.backend_access_key_id.arn
  backend_secret_key_param_arn = aws_ssm_parameter.backend_secret_access_key.arn
  backend_s3_bucket            = each.value.backend.s3_bucket



  # EKS knobs
  cluster_version = each.value.cluster_version
  instance_types  = each.value.instance_types
  capacity_type   = each.value.capacity_type
  min_size        = each.value.min_nodes
  max_size        = each.value.max_nodes
  desired_size    = each.value.desired_nodes

  # Database knobs (Aurora PostgreSQL Serverless v2)
  db_engine_version              = each.value.db_engine_version
  db_name                        = each.value.db_name
  db_username                    = each.value.db_username
  serverlessv2_min_capacity_acus = each.value.min_acus
  serverlessv2_max_capacity_acus = each.value.max_acus

  # Global
  tenant_name         = local.effective_tenant
  account_id          = local.global_config.account_id
  alerts_email        = local.global_config.alerts_email
  company_vpn_cidr    = local.global_config.company_vpn_cidr
  enable_slack_alerts = local.global_config.enable_slack_alerts
  slack_hook_uri      = local.global_config.slack_hook_uri

  # Per-env map
  env_config = local.environments
}

  # Locals Per-Env
  # ----------------------
  
locals {
  base_domain = local.global_config.base_domain

  # choose the first enabled environment (e.g., "prod")
  primary_env = local.enabled_environments[0]

  # per-env app host (e.g., ria.vytalmed.app)
  app_host = "${local.environments[local.primary_env].app_subdomain}.${local.base_domain}"
  
  # NLB Name
  ingress_nlb_name = "${lower(local.effective_tenant)}-${local.primary_env}-ing" # keep <=32 chars

  # per-env Argo CD host map and the selected one for the primary env
  argocd_hosts = {
    for env, _ in local.environments :
    env => "argocd.${local.base_domain}"
  }
  argocd_host = lookup(local.argocd_hosts, local.primary_env, "argocd.${local.base_domain}")
}


  # Locals Global
  # ----------------------

locals {
  effective_tenant = coalesce(var.tenant_name, local.global_config.tenant_name)
  effective_region = coalesce(var.region, local.global_config.region)

  # Check if Karpenter is enabled in the primary environment
  karpenter_enabled = try(local.environments[local.primary_env].karpenter.enabled, false)
  # keep in sync with compatibility matrix
  karpenter_version = try(
    local.environments[local.primary_env].karpenter.version,
    "1.8.1"
  )

  # Check if monitoring is enabled in the primary environment
  monitoring_enabled = try(local.environments[local.primary_env].monitoring.enabled, true)

  # Bastion instance name tag
  bastion_name = "${lower(local.effective_tenant)}-${local.effective_region}-bastion"

  # Common naming prefix for root-level resources
  name_prefix = lower("${local.effective_tenant}-${local.primary_env}")

  # Common tags for root-level resources
  tags = {
    Tenant    = local.effective_tenant
    Region    = local.effective_region
    Env       = local.primary_env
    Terraform = "true"
    ManagedBy = "Terraform"
  }
}


  # GLOBAL CONFIGURATION
  # ----------------------

  # Account-level EBS Encryption By default
resource "aws_ebs_encryption_by_default" "main" {
  enabled = local.account_global["EBSEncEnabled"]
}