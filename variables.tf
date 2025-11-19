###=================== Account & Region ===================###

# variables.tf
variable "account_id" {
  type        = string
  default     = null
  description = "The ID of the AWS account."
}

variable "tenant_name" {
  type        = string
  default     = null
  description = "Tenant/company short name used in resource names."
}

variable "region" {
  type        = string
  default     = null
  description = "AWS region for deployment."
}


###======================= VPC ========================###

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "172.31.0.0/16"
}

variable "public_subnet_az_1_CIDR" {
  description = "CIDR block for Public Subnet AZ 1"
  type        = string
  default     = "172.31.0.0/24"
}

variable "public_subnet_az_2_CIDR" {
  description = "CIDR block for Public Subnet AZ 2"
  type        = string
  default     = "172.31.1.0/24"
}

variable "private_subnet_az_1_CIDR" {
  description = "CIDR block for Private Subnet AZ 1"
  type        = string
  default     = "172.31.2.0/24"
}

variable "private_subnet_az_2_CIDR" {
  description = "CIDR block for Private Subnet AZ 2"
  type        = string
  default     = "172.31.3.0/24"
}

###=================== EKS settings ===================###
variable "cluster_version" {
  description = "EKS version (e.g., 1.31). If null, module default is used."
  type        = string
  default     = null
}

variable "eks_instance_types" {
  description = "Node group instance types"
  type        = list(string)
  default     = ["m6i.large"]
}

variable "eks_capacity_type" {
  description = "ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "eks_min_nodes" {
  type    = number
  default = 1
}

variable "eks_max_nodes" {
  type    = number
  default = 3
}

variable "eks_desired_nodes" {
  type    = number
  default = 1
}

###=================== DB settings (Aurora PG Srvls v2) ===================###
variable "db_engine_version" {
  description = "Aurora PostgreSQL major version (e.g., 15)"
  type        = string
  default     = "15"
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "DB master username"
  type        = string
  default     = null
}

# Aurora Serverless v2 capacity in ACUs (0.5 - 128 per instance)
variable "serverlessv2_min_capacity_acus" {
  type    = number
  default = 0.5
}

variable "serverlessv2_max_capacity_acus" {
  type    = number
  default = 4
}


###================== Karpenter ==================###

variable "karpenter_version" {
  description = "Karpenter version (e.g., 1.8.1). Can be overridden per-environment. See https://github.com/aws/karpenter-provider-aws/releases"
  type        = string
  default     = "1.8.1"
}

###================== Feature Toggles ==================###

variable "enable_slack_alerts" {
  description = "Enable Slack alert Lambda"
  type        = bool
  default     = true
}

variable "slack_hook_uri" {
  description = "Slack webhook URI used by Lambda"
  type        = string
  default     = "" # Or set a real default if you want, or override via CLI/TFC/env
}

###================== Groups Ingress ==================###

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
