variable "enable_redis" {
  type    = bool
  default = true
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.small"
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

variable "redis_num_replicas" {
  type    = number
  default = 1
}

variable "redis_port" {
  type    = number
  default = 6379
}

locals {
  redis_auth_param = "/envs/${var.env_name}/redis/auth"
  redis_url_param  = "/envs/${var.env_name}/redis/url"
}

# SG for Redis
resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis"
  description = "Redis access"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

# Only EKS nodes can reach Redis
resource "aws_security_group_rule" "redis_from_nodes" {
  type                     = "ingress"
  security_group_id        = aws_security_group.redis.id
  from_port                = var.redis_port
  to_port                  = var.redis_port
  protocol                 = "tcp"
  source_security_group_id = module.eks.node_security_group_id
}

resource "aws_security_group_rule" "redis_egress" {
  type              = "egress"
  security_group_id = aws_security_group.redis.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

# ---- Subnet/parameter groups ----
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.name_prefix}-redis-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = local.tags
}

resource "aws_elasticache_parameter_group" "redis" {
  name   = "${local.name_prefix}-redis-pg"
  family = "redis7"
  tags   = local.tags
}

# ---- Auth token in SSM (generated once by TF) ----
resource "random_password" "redis_auth" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "redis_auth" {
  name  = local.redis_auth_param
  type  = "SecureString"
  value = random_password.redis_auth.result
  tags  = local.tags
}

# ---- The Redis replication group ----
resource "aws_elasticache_replication_group" "redis" {
  count                        = var.enable_redis ? 1 : 0

  replication_group_id         = "${lower(local.name_prefix)}-redis"
  description                  = "Redis for ${local.name_prefix}"
  engine                       = "redis"
  engine_version               = var.redis_engine_version
  node_type                    = var.redis_node_type

  num_node_groups              = 1
  replicas_per_node_group      = var.redis_num_replicas
  automatic_failover_enabled   = var.redis_num_replicas > 0
  multi_az_enabled             = true

  port                         = var.redis_port
  subnet_group_name            = aws_elasticache_subnet_group.redis.name
  parameter_group_name         = aws_elasticache_parameter_group.redis.name
  security_group_ids           = [aws_security_group.redis.id]

  at_rest_encryption_enabled   = true
  transit_encryption_enabled   = true
  auth_token                   = random_password.redis_auth.result

  tags = local.tags
}

# Optional convenience param with a TLS URL your app can use directly
resource "aws_ssm_parameter" "redis_url" {
  count = var.enable_redis ? 1 : 0
  name  = local.redis_url_param
  type  = "String"
  value = "rediss://${aws_elasticache_replication_group.redis[0].primary_endpoint_address}:${var.redis_port}"
  tags  = local.tags
}

output "redis_primary_endpoint" {
  value       = try(aws_elasticache_replication_group.redis[0].primary_endpoint_address, null)
  description = "Redis primary endpoint"
}

output "redis_auth_param_name" {
  value       = local.redis_auth_param
  description = "SSM param name for Redis AUTH token"
}

output "redis_url_param_name" {
  value       = local.redis_url_param
  description = "SSM param name for rediss:// URL"
}