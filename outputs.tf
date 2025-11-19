
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
