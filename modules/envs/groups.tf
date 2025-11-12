# Bastion SG
resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-bastion-sg"
  description = "Allow SSH access to Bastion host"
  vpc_id      = var.vpc_id

  # Tag the SG (includes a human-friendly Name)
  tags = merge(local.tags, {
    Name = "${local.name_prefix}-bastion-sg"
  })
}

# Create the SSH rule only if a VPN CIDR is provided
resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  count             = var.company_vpn_cidr == null ? 0 : 1
  security_group_id = aws_security_group.bastion.id
  description       = "Company VPN"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.company_vpn_cidr
}

# Egress (allow all) as a standalone rule
resource "aws_vpc_security_group_egress_rule" "bastion_all_egress" {
  security_group_id = aws_security_group.bastion.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Allow kubectl from Bastion to EKS control plane (private endpoint)
resource "aws_vpc_security_group_ingress_rule" "eks_api_from_bastion" {
  count                    = var.enable_bastion ? 1 : 0
  security_group_id        = module.eks.cluster_security_group_id  # same as your output cluster_sg_id
  description              = "Allow EKS API (443) from bastion"
  ip_protocol              = "tcp"
  from_port                = 443
  to_port                  = 443
  referenced_security_group_id = aws_security_group.bastion.id
}


# -----------------------------
# DB SG rules (extra ingress)
# -----------------------------
resource "aws_vpc_security_group_ingress_rule" "db_extra" {
  for_each = {
    for idx, r in lookup(var.extra_ingress, "db", []) :
    idx => r
  }

  security_group_id = aws_security_group.aurora.id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.from
  to_port           = each.value.to

  # Keep simple: first CIDR if provided; (use a nested for_each if you want one rule per CIDR)
  cidr_ipv4       = try(each.value.cidrs[0], null)
  prefix_list_id  = null
}

# -----------------------------
# Bastion SG rules (extra ingress)
# -----------------------------
resource "aws_vpc_security_group_ingress_rule" "bastion_extra" {
  for_each = {
    for idx, r in lookup(var.extra_ingress, "bastion", []) :
    idx => r
  }

  security_group_id = aws_security_group.bastion.id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.from
  to_port           = each.value.to
  cidr_ipv4         = try(each.value.cidrs[0], null)
}

# -----------------------------
# EKS node SG rules (extra ingress)
# -----------------------------
resource "aws_vpc_security_group_ingress_rule" "eks_nodes_extra" {
  # for_each must be plan-time known: base only on var.extra_ingress
  for_each = {
    for i, r in lookup(var.extra_ingress, "eks_nodes", []) : i => r
  }

  # this can be unknown until apply; that's fine
  security_group_id = local.eks_node_sg_id

  description = each.value.description
  ip_protocol = each.value.protocol
  from_port   = each.value.from
  to_port     = each.value.to
  cidr_ipv4   = try(each.value.cidrs[0], null)

  # Make sure EKS (and its node SG) exists first
  depends_on = [module.eks]
}