
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
