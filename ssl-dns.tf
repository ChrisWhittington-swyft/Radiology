# Create placeholder SSM parameter that will be updated by the bootstrap script
resource "aws_ssm_parameter" "ingress_nlb_placeholder" {
  name  = "/eks/${module.envs[local.primary_env].eks_cluster_name}/ingress_nlb_hostname"
  type  = "String"
  value = "pending"

  lifecycle {
    ignore_changes = [value]
  }

  depends_on = [module.envs]
}

# Poll SSM parameter until it's updated with real NLB hostname (not "pending")
resource "null_resource" "wait_for_nlb_hostname" {
  depends_on = [
    aws_ssm_association.bootstrap_ingress_now,
    aws_ssm_parameter.ingress_nlb_placeholder
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      PARAM_NAME="/eks/${module.envs[local.primary_env].eks_cluster_name}/ingress_nlb_hostname"
      REGION="${local.effective_region}"

      echo "Waiting for NLB hostname in SSM parameter: $PARAM_NAME"

      for i in $(seq 1 60); do
        VALUE=$(aws ssm get-parameter --name "$PARAM_NAME" --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "pending")

        if [ "$VALUE" != "pending" ] && [ -n "$VALUE" ]; then
          echo "✓ NLB hostname available: $VALUE"
          exit 0
        fi

        echo "Waiting for NLB hostname... ($i/60) - current value: $VALUE"
        sleep 10
      done

      echo "ERROR: Timeout waiting for NLB hostname after 10 minutes"
      exit 1
    EOT
  }

  triggers = {
    association_id = aws_ssm_association.bootstrap_ingress_now.association_id
  }
}

data "aws_ssm_parameter" "ingress_nlb" {
  depends_on = [null_resource.wait_for_nlb_hostname]
  name       = "/eks/${module.envs[local.primary_env].eks_cluster_name}/ingress_nlb_hostname"
}


data "aws_route53_zone" "vytalmed" {
  provider     = aws.dns
  name         = "${local.global_config.base_domain}."
  private_zone = false
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


# ArgoCD host → NLB
resource "aws_route53_record" "argocd" {
  provider = aws.dns
  zone_id  = data.aws_route53_zone.vytalmed.zone_id
  name     = local.argocd_host         # e.g., argocd-dev.vytalmed.app or argocd.vytalmed.app
  type     = "CNAME"
  ttl      = 60
  records  = [data.aws_ssm_parameter.ingress_nlb.value]
  allow_overwrite = true

  depends_on = [aws_ssm_association.argocd_ingress_now]
}

# Prod front-end → NLB
resource "aws_route53_record" "subdomain-prod" {
  provider = aws.dns
  zone_id  = data.aws_route53_zone.vytalmed.zone_id
  name     = local.environments[local.primary_env].app_subdomain         # e.g., prod.vytalmed.app
  type     = "CNAME"
  ttl      = 60
  records  = [data.aws_ssm_parameter.ingress_nlb.value]
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