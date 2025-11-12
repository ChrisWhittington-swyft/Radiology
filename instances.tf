locals {
  global_config = {
    region              = "us-east-1"
    account_id          = "084134273524"
    tenant_name         = "vytalmed"
    base_domain         = "vytalmed.app"
    alerts_email        = ["support@nymbl.app"]
    enable_slack_alerts = false
    slack_hook_uri      = "https://hooks.slack.com/services/XXX/YYY/ZZZ"
    elb_security_policy = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
    company_vpn_cidr    = "34.227.217.58/32"
    sso_admin_role_arn  =  "arn:aws:iam::084134273524:role/PlaceHolderRole"
  }

  environments = {
    prod = {
      # EKS
      cluster_version = "1.34"
      instance_types  = ["m5.xlarge"]
      capacity_type   = "ON_DEMAND"
      min_nodes       = 2
      max_nodes       = 10
      desired_nodes   = 3

      # Aurora Serverless v2
      db_engine_version = "15"
      db_name           = "worklist"
      db_username       = "worklist"
      min_acus          = 6
      max_acus          = 24

      # app host subdomain for this env
      app_subdomain     = "prod"

      # ArgoCD per-env
    argocd = {
      repo_url            = "https://github.com/BeNYMBL/Vytalmed-prod.git"
      repo_username       = "oauth2"                                            # GitHub with PAT
      repo_pat_param_name = "/bootstrap/github_pat_ria"
      app_of_apps_path    = "clusters/${local.primary_env}"
      project             = "default"
    }
      # Back-end
    backend = {
      kafka_server          = "kafka:9092"
      sms_account_sid_value = "ACc2f9ba0fda5ea13b0a6c8f4ddf512657"
      sms_auth_token_value  = "d1ec6fb436a71444f650622013fecb76"
      sms_phone_number      = "+17027186630"
      s3_bucket             = "vytalmed-prod-us-east-1"
      s3_prefix             = "incoming-faxes-lambda/"
      aws_access_key_id     = "/bootstrap/backend/aws_access_key_id"
      aws_secret_key        = "/bootstrap/backend/aws_secret_access_key"
      test_mode             = "false"
      ai_mock_mode          = "false"
      spring_ai_enabled     = "true"
    }
     # Karpenter Settings
  karpenter = {
      enabled = true
      
      # Interruption queue name (will be prefixed with cluster name)
      interruption_queue_name = "karpenter"
      
      # NodePool settings
      nodepool = {
        limits = {
          cpu    = "800"
          memory = "1600Gi"
        }
        disruption = {
          consolidation_policy = "WhenEmptyOrUnderutilized"
          consolidate_after    = "30s"
          expire_after         = "720h"  # 30 days
        }
      }
      
      # EC2NodeClass settings
      ec2nodeclass = {
        ami_family = "AL2023"
        instance_families = ["m5", "m6a", "c6a"]
        instance_sizes    = ["large", "xlarge"]
        capacity_types    = ["spot", "on-demand"]
      }
    }
# Groups per-env
      extra_ingress = {
  #DB
        # db = [
        #   {
        #     description = "Office → Postgres"
        #     protocol    = "tcp"
        #     from        = 5432
        #     to          = 5432
        #     cidrs       = ["34.227.217.58/32"]
        #   }
        # ]
  #Bastion
        # bastion = [
        #   {
        #     description = "Admin → SSH"
        #     protocol    = "tcp"
        #     from        = 22
        #     to          = 22
        #     cidrs       = ["34.227.217.58/32"]
        #   }
        # ]
  #EKS
        eks_nodes = [
          {
            description = "NodePort range for NLB (instance mode)"
            protocol    = "tcp"
            from        = 30000
            to          = 32767
            cidrs       = ["0.0.0.0/0"]
          }
        ]
      }
    }
  }

  enabled_environments = ["prod"]

  account_global = {
    EBSEncEnabled = "true"
  }
}
