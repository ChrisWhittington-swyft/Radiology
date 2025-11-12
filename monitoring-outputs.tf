############################################
# Monitoring Outputs
############################################

output "amp_workspace_id" {
  description = "Amazon Managed Prometheus workspace ID"
  value       = try(module.envs[local.primary_env].amp_workspace_id, null)
}

output "amp_workspace_url" {
  description = "Amazon Managed Prometheus workspace URL"
  value = try(
    "https://aps-workspaces.${local.effective_region}.amazonaws.com/workspaces/${module.envs[local.primary_env].amp_workspace_id}",
    null
  )
}

output "grafana_workspace_id" {
  description = "Amazon Managed Grafana workspace ID"
  value       = try(module.envs[local.primary_env].grafana_workspace_id, null)
}

output "grafana_workspace_url" {
  description = "Amazon Managed Grafana workspace URL"
  value       = try(module.envs[local.primary_env].grafana_workspace_endpoint, null)
}

output "monitoring_enabled" {
  description = "Whether monitoring is enabled"
  value       = try(module.envs[local.primary_env].monitoring_enabled, false)
}
