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

resource "aws_ssm_parameter" "env_argocd_hosts" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/argocd/host"
  type  = "String"
  value = "argocd.${local.base_domain}"

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "ArgoCD UI host for ${each.key}"
  }
}

# Backend Configuration Parameters
resource "aws_ssm_parameter" "env_backend_secret_names" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/secret_name"
  type  = "String"
  value = local.environments[each.key].backend.secret_name

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Backend Kubernetes secret name for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_backend_secret_namespaces" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/secret_namespace"
  type  = "String"
  value = local.environments[each.key].backend.secret_namespace

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Backend Kubernetes secret namespace for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_backend_kafka_servers" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/kafka_server"
  type  = "String"
  value = local.environments[each.key].backend.kafka_server

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Kafka server for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_backend_aws_key_params" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/aws_access_key_param"
  type  = "String"
  value = local.environments[each.key].backend.aws_access_key_id

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "AWS Access Key ID parameter path for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_backend_aws_secret_params" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/aws_secret_key_param"
  type  = "String"
  value = local.environments[each.key].backend.aws_secret_key

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "AWS Secret Key parameter path for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_backend_s3_buckets" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/s3_bucket"
  type  = "String"
  value = local.environments[each.key].backend.s3_bucket

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "S3 Bucket for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_backend_s3_prefixes" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/s3_prefix"
  type  = "String"
  value = local.environments[each.key].backend.s3_prefix

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "S3 Prefix for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_backend_test_modes" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/test_mode"
  type  = "String"
  value = local.environments[each.key].backend.test_mode

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Test mode flag for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_backend_ai_mock_modes" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/ai_mock_mode"
  type  = "String"
  value = local.environments[each.key].backend.ai_mock_mode

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "AI mock mode flag for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_backend_spring_ai_enabled" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/backend/spring_ai_enabled"
  type  = "String"
  value = local.environments[each.key].backend.spring_ai_enabled

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Spring AI enabled flag for ${each.key}"
  }
}

# Karpenter Configuration Parameters
resource "aws_ssm_parameter" "env_karpenter_enabled" {
  for_each = toset(local.enabled_environments)

  name  = "/terraform/envs/${each.key}/karpenter/enabled"
  type  = "String"
  value = tostring(try(local.environments[each.key].karpenter.enabled, false))

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Karpenter enabled flag for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_karpenter_version" {
  for_each = {
    for k in local.enabled_environments : k => k
    if try(local.environments[k].karpenter.enabled, false)
  }

  name  = "/terraform/envs/${each.key}/karpenter/version"
  type  = "String"
  value = try(local.environments[each.key].karpenter.version, var.karpenter_version)

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Karpenter version for ${each.key}"
  }
}

# Module Output Parameters (from envs module - stored in legacy /eks path for compatibility)

resource "aws_ssm_parameter" "env_encryption_secrets" {
  for_each = toset(local.enabled_environments)

  name  = "/eks/${module.envs[each.key].eks_cluster_name}/encryption_secret"
  type  = "SecureString"
  value = module.envs[each.key].encryption_secret

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Encryption secret for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_redis_auth_params" {
  for_each = toset(local.enabled_environments)

  name  = "/eks/${module.envs[each.key].eks_cluster_name}/redis/auth_param"
  type  = "String"
  value = module.envs[each.key].redis_auth_param_name

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Redis auth parameter path for ${each.key}"
  }
}

resource "aws_ssm_parameter" "env_redis_url_params" {
  for_each = toset(local.enabled_environments)

  name  = "/eks/${module.envs[each.key].eks_cluster_name}/redis/url_param"
  type  = "String"
  value = module.envs[each.key].redis_url_param_name

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Redis URL parameter path for ${each.key}"
  }
}

