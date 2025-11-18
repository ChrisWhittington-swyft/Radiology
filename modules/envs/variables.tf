variable "region" {
  type        = string
  description = "AWS region for this environment"
}

#Customer/AWS
variable "tenant_name"         { type = string }
variable "account_id"          { type = string }
variable "env_name"            { type = string }

#Network
variable "vpc_id"              { type = string }
variable "private_subnet_ids"  { type = list(string) }
variable "public_subnet_ids"   { type = list(string) }

#Domain Base
# variable "base_domain" {
#   type        = string
#   description = "Base DNS suffix (e.g., nymbl.host)."
# }

# variable "dns_zone_id" {
#   type        = string
#   description = "Hosted zone ID in the DNS account for base_domain."
# }

#Jump Host
variable "enable_bastion" {
  type        = bool
  default     = true
  description = "Create a bastion host"
}

variable "bastion_instance_type" {
  type        = string
  default     = "t3.small"
}

variable "bastion_public" {
  type        = bool
  default     = false # true => public IP + place in public subnet
}

variable "bastion_keypair" {
  type        = string
  default     = null
  description = "EC2 key pair name for SSH/RDP access to bastion hosts"
}

# SSO - optional

variable "sso_admin_role_arn" {
  type        = string
  default     = null
  description = "Optional: AWSReservedSSO role ARN to grant EKS cluster-admin."
  validation {
    condition     = var.sso_admin_role_arn == null || can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.sso_admin_role_arn))
    error_message = "sso_admin_role_arn must be a valid role ARN or null."
  }
}

# EKS
variable "cluster_version" {
  type    = string
  default = null
}

variable "instance_types" {
  type = list(string)
}

variable "capacity_type" {
  type = string
}

variable "min_size" {
  type = number
}

variable "max_size" {
  type = number
}

variable "desired_size" {
  type = number
}

# modules/envs/variables.tf
variable "eks_node_sg_id" {
  type        = string
  description = "EKS node group security group ID"
  default     = null
}


# Aurora PG Serverless v2
variable "db_engine_version" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "serverlessv2_min_capacity_acus" {
  type = number
}

variable "serverlessv2_max_capacity_acus" {
  type = number
}


variable "company_vpn_cidr" {
  type        = string
  description = "CIDR block for company VPN IP"
  default     = null
}

variable "datavysta_richard_ips" {
  type        = list(string)
  description = "List of CIDR blocks for DataVysta Richard's access"
  default     = []
}

variable "enabled_environments" {
  description = "List of enabled environments"
  type        = list(string)
}

variable "alerts_email" {
  type        = list(string)
  description = "List of email addresses to subscribe to SNS alerts"
}

variable "slack_hook_uri" {
  type        = string
  description = "Slack webhook for Lambda alerts"
}

variable "enable_slack_alerts" {
  type        = bool
  default     = false
  description = "Whether to enable Lambda-based Slack alerting"
}

variable "create_low_disk_burst_alarm" {
  description = "Whether to create RDS disk burst balance alarms"
  type        = bool
  default     = false
}

variable "create_low_cpu_credit_alarm" {
  description = "Whether to create RDS CPU credit balance alarms"
  type        = bool
  default     = false
}

variable "env_config" {
  description = "Map of environment configurations"
  type        = map(any)
}

variable "extra_ingress" {
  description = "Extra ingress rules per SG target {db,bastion,eks_nodes}"
  type = map(list(object({
    description = string
    protocol    = string
    from        = number
    to          = number
    cidrs       = optional(list(string), [])
    sg_ids      = optional(list(string), [])
  })))
  default = {}
}

variable "backend_access_key_param_arn" {
  type    = string
  default = null
}

variable "backend_secret_key_param_arn" {
  type    = string
  default = null
}
