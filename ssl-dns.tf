data "aws_route53_zone" "vytalmed" {
  provider     = aws.dns
  name         = "${local.global_config.base_domain}."
  private_zone = false
}

# Look up the NLB created by the ingress controller for each environment
data "aws_lb" "ingress_nlb" {
  for_each = toset(local.enabled_environments)

  name = "${lower(local.effective_tenant)}-${each.key}-ing"

  depends_on = [
    aws_ssm_association.bootstrap_ingress_now
  ]
}

#############################################
# Wildcard ACM cert in workload account/region
#############################################
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${local.global_config.base_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name      = "wildcard-${local.global_config.base_domain}"
    ManagedBy = "Terraform"
  }
}

# Create DNS validation records in the DNS account
resource "aws_route53_record" "wildcard_validation" {
  provider = aws.dns

  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.vytalmed.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.wildcard_validation : r.fqdn]
}


# ArgoCD host → Primary env NLB (shared ArgoCD for all envs)
resource "aws_route53_record" "argocd" {
  provider = aws.dns
  zone_id  = data.aws_route53_zone.vytalmed.zone_id
  name     = local.argocd_host         # e.g., argocd.vytalmed.app
  type     = "CNAME"
  ttl      = 60
  records  = [data.aws_lb.ingress_nlb[local.primary_env].dns_name]
  allow_overwrite = true

  depends_on = [aws_ssm_association.argocd_ingress_now]
}

# Per-environment app subdomain → NLB
resource "aws_route53_record" "app_subdomain" {
  for_each = toset(local.enabled_environments)

  provider = aws.dns
  zone_id  = data.aws_route53_zone.vytalmed.zone_id
  name     = local.environments[each.key].app_subdomain         # e.g., ria.vytalmed.app, ria-dev.vytalmed.app
  type     = "CNAME"
  ttl      = 60
  records  = [data.aws_lb.ingress_nlb[each.key].dns_name]
  allow_overwrite = true

  depends_on = [aws_ssm_association.backend_secret_now]
}

# Windows Bastion DNS record → Elastic IP
resource "aws_route53_record" "bastion_windows" {
  for_each = {
    for k, v in local.environments : k => v
    if contains(local.enabled_environments, k) && try(v.enable_windows_bastion, false)
  }

  provider = aws.dns
  zone_id  = data.aws_route53_zone.vytalmed.zone_id
  name     = "bastion.${local.global_config.base_domain}"
  type     = "A"
  ttl      = 60
  records  = [module.envs[each.key].bastion_windows_public_ip]
  allow_overwrite = true
}