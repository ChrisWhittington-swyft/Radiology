# Shared SSM Parameters (region, ACM ARN)
resource "aws_ssm_parameter" "shared_region" {
  name  = "/terraform/shared/region"
  type  = "String"
  value = local.effective_region

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "Shared configuration for SSM documents"
  }
}

resource "aws_ssm_parameter" "shared_acm_arn" {
  name  = "/terraform/shared/acm_arn"
  type  = "String"
  value = aws_acm_certificate.wildcard.arn

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "Shared ACM certificate ARN"
  }

  depends_on = [
    aws_acm_certificate.wildcard
  ]
}

# Per-Environment SSM Parameters
resource "aws_ssm_parameter" "env_cluster_names" {
  for_each = { for k, v in module.envs : k => v.cluster_name }

  name  = "/terraform/envs/${each.key}/cluster_name"
  type  = "String"
  value = each.value

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "EKS cluster name for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_app_hosts" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/app_host"
  type  = "String"
  value = "${local.environments[each.key].app_subdomain}.${local.base_domain}"

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Application host for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_ingress_nlb_names" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/ingress_nlb_name"
  type  = "String"
  value = "${lower(local.effective_tenant)}-${each.key}-ing"

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Ingress NLB name for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_dockerhub_user_params" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/dockerhub_user_param"
  type  = "String"
  value = local.environments[each.key].argocd.dockerhub_user_param

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "DockerHub user parameter path for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_dockerhub_pass_params" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/dockerhub_pass_param"
  type  = "String"
  value = local.environments[each.key].argocd.dockerhub_pass_param

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "DockerHub password parameter path for ${each.key}"
  }
}

# ArgoCD Configuration Parameters
resource "aws_ssm_parameter" "env_argocd_repo_urls" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/argocd/repo_url"
  type  = "String"
  value = local.environments[each.key].argocd.repo_url

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "ArgoCD repository URL for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_argocd_repo_usernames" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/argocd/repo_username"
  type  = "String"
  value = local.environments[each.key].argocd.repo_username

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "ArgoCD repository username for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_argocd_repo_pat_params" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/argocd/repo_pat_param"
  type  = "String"
  value = local.environments[each.key].argocd.repo_pat_param_name

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "ArgoCD PAT parameter path for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_argocd_app_paths" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/argocd/app_path"
  type  = "String"
  value = local.environments[each.key].argocd.app_of_apps_path

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "ArgoCD app-of-apps path for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_argocd_projects" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/argocd/project"
  type  = "String"
  value = local.environments[each.key].argocd.project

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "ArgoCD project name for ${each.key}"
  }
}
