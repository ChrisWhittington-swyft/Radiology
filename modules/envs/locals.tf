locals {
  name_prefix = lower("${var.tenant_name}-${var.env_name}")
  eks_node_sg_id = try(module.eks.node_security_group_id, null)
  tags = {
    Tenant    = var.tenant_name
    Region    = var.region
    Env       = var.env_name
    Terraform = "true"
    ManagedBy = "Terraform"
  }
}

# Generate encryption secret for DB
resource "random_password" "encryption_secret" {
  length  = 32
  special = true
}