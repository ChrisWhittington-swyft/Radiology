############################################
# Monitoring Outputs (per environment)
############################################

output "amp_workspace_ids" {
  description = "Amazon Managed Prometheus workspace IDs per environment"
  value       = { for k, v in module.envs : k => v.amp_workspace_id if v.monitoring_enabled }
}

output "amp_workspace_urls" {
  description = "Amazon Managed Prometheus workspace URLs per environment"
  value = {
    for k, v in module.envs : k => "https://aps-workspaces.${local.effective_region}.amazonaws.com/workspaces/${v.amp_workspace_id}"
    if v.monitoring_enabled && v.amp_workspace_id != null
  }
}

output "grafana_workspace_ids" {
  description = "Amazon Managed Grafana workspace IDs per environment"
  value       = { for k, v in module.envs : k => v.grafana_workspace_id if v.monitoring_enabled }
}

output "grafana_workspace_urls" {
  description = "Amazon Managed Grafana workspace URLs per environment"
  value       = { for k, v in module.envs : k => v.grafana_workspace_endpoint if v.monitoring_enabled }
}
