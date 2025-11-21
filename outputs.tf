
##############################################
# Outputs
##############################################

output "eks_cluster_names" {
  value = { for k, m in module.envs : k => m.cluster_name }
}

output "eks_cluster_arns" {
  value = { for k, m in module.envs : k => m.cluster_arn }
}

output "db_writer_endpoints" {
  value = { for k, m in module.envs : k => m.db_writer_endpoint }
}

output "db_secret_arns" {
  value = { for k, m in module.envs : k => m.db_secret_arn }
  sensitive = true
}

output "karpenter_controller_role_arns" {
  description = "Karpenter controller IAM role ARNs per environment"
  value       = { for k, m in module.envs : k => m.karpenter_controller_role_arn if m.karpenter_enabled }
}

output "karpenter_node_instance_profiles" {
  description = "Karpenter node instance profiles per environment"
  value       = { for k, m in module.envs : k => m.karpenter_node_instance_profile if m.karpenter_enabled }
}
output "kafka_bootstrap_servers" {
  description = "MSK Serverless bootstrap servers per environment"
  value       = { for k, m in module.envs : k => m.kafka_bootstrap_servers if m.kafka_enabled }
}

output "kafka_cluster_arns" {
  description = "MSK Serverless cluster ARNs per environment"
  value       = { for k, m in module.envs : k => m.kafka_cluster_arn if m.kafka_enabled }
}

output "bastion_windows_instance_ids" {
  description = "Windows bastion instance IDs per environment"
  value       = { for k, m in module.envs : k => m.bastion_windows_instance_id if try(m.bastion_windows_instance_id, null) != null }
}

output "bastion_windows_private_ips" {
  description = "Windows bastion private IPs per environment"
  value       = { for k, m in module.envs : k => m.bastion_windows_private_ip if try(m.bastion_windows_private_ip, null) != null }
}

output "bastion_windows_public_ips" {
  description = "Windows bastion public IPs per environment"
  value       = { for k, m in module.envs : k => m.bastion_windows_public_ip if try(m.bastion_windows_public_ip, null) != null }
}

output "ingress_nlb_dns_status" {
  description = "Status of ingress NLB DNS hostnames (run 'terraform apply' again if pending)"
  value = {
    for env in local.enabled_environments : env => {
      ssm_parameter = "/terraform/envs/${env}/ingress_nlb_dns"
      current_value = data.aws_ssm_parameter.ingress_nlb_dns[env].value
      status        = data.aws_ssm_parameter.ingress_nlb_dns[env].value == "pending" ? "⏳ NLB not ready - rerun terraform apply after ~10 min" : "✓ Ready"
      app_url       = "https://${local.environments[env].app_subdomain}"
    }
  }
}

output "post_deployment_instructions" {
  description = "Next steps after initial deployment"
  value = anytrue([for env in local.enabled_environments : data.aws_ssm_parameter.ingress_nlb_dns[env].value == "pending"]) ? <<-EOT

    ⚠️  NEXT STEPS REQUIRED:

    The ingress NLBs are being created by Kubernetes (takes ~10 minutes).
    Once created, the bootstrap script will update SSM parameters.

    After ~10-15 minutes, run:
        terraform apply

    This will create the Route53 DNS records pointing to your NLBs.

  EOT : <<-EOT

    ✓ All DNS records created successfully!

    Application URLs:
    ${join("\n    ", [for env in local.enabled_environments : "- ${env}: https://${local.environments[env].app_subdomain}"])}

    ArgoCD UI: https://${local.argocd_host}

  EOT
}
