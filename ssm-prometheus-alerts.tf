############################################
# SSM Document: Configure Custom Prometheus Alert Rules
############################################

resource "aws_ssm_document" "prometheus_alerts" {
  count         = local.karpenter_enabled ? 1 : 0
  name          = "${lower(local.effective_tenant)}-${local.primary_env}-prometheus-alerts"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Configure custom Prometheus alert rules for critical infrastructure monitoring"

    parameters = {
      Region = {
        type    = "String"
        default = local.effective_region
      }
      ClusterName = {
        type    = "String"
        default = module.envs[local.primary_env].eks_cluster_name
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "ConfigureAlerts"
        inputs = {
          timeoutSeconds = 300
          runCommand = [
            "#!/bin/bash",
            "set -Eeuo pipefail",
            "exec 2>&1",

            "REGION='{{Region}}'",
            "CLUSTER_NAME='{{ClusterName}}'",

            "export HOME=/root",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",

            "echo \"[Alerts] Configuring custom Prometheus alert rules...\"",

            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",

            "echo \"[Alerts] Creating custom alert rules\"",
            "cat <<'RULES_EOF' | kubectl apply -f -",
            "apiVersion: monitoring.coreos.com/v1",
            "kind: PrometheusRule",
            "metadata:",
            "  name: custom-infrastructure-alerts",
            "  namespace: monitoring",
            "  labels:",
            "    prometheus: kube-prometheus",
            "    role: alert-rules",
            "spec:",
            "  groups:",
            "  - name: infrastructure",
            "    interval: 30s",
            "    rules:",
            "    - alert: NodeDown",
            "      expr: up{job=\"node-exporter\"} == 0",
            "      for: 2m",
            "      labels:",
            "        severity: critical",
            "      annotations:",
            "        summary: Node {{ $labels.instance }} is down",
            "        description: Node exporter on {{ $labels.instance }} has been down for more than 2 minutes.",
            "",
            "    - alert: HighNodeCPU",
            "      expr: (100 - (avg by (instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)) > 85",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: High CPU usage on {{ $labels.instance }}",
            "        description: Node {{ $labels.instance }} has CPU usage above 85% for more than 10 minutes (current: {{ $value }}%).",
            "",
            "    - alert: HighNodeMemory",
            "      expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: High memory usage on {{ $labels.instance }}",
            "        description: Node {{ $labels.instance }} has memory usage above 85% for more than 10 minutes (current: {{ $value }}%).",
            "",
            "    - alert: NodeDiskSpaceLow",
            "      expr: (node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100 < 15",
            "      for: 5m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: Low disk space on {{ $labels.instance }}",
            "        description: Node {{ $labels.instance }} has less than 15% disk space remaining (current: {{ $value }}%).",
            "",
            "    - alert: PodCrashLooping",
            "      expr: rate(kube_pod_container_status_restarts_total[15m]) > 0",
            "      for: 5m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash looping",
            "        description: Pod {{ $labels.namespace }}/{{ $labels.pod }} container {{ $labels.container }} has restarted {{ $value }} times in the last 15 minutes.",
            "",
            "    - alert: PodNotReady",
            "      expr: sum by (namespace, pod) (kube_pod_status_phase{phase!~\"Running|Succeeded\"}) > 0",
            "      for: 15m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: Pod {{ $labels.namespace }}/{{ $labels.pod }} not ready",
            "        description: Pod {{ $labels.namespace }}/{{ $labels.pod }} has been in a non-ready state for more than 15 minutes.",
            "",
            "    - alert: DeploymentReplicasMismatch",
            "      expr: kube_deployment_spec_replicas != kube_deployment_status_replicas_available",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: Deployment {{ $labels.namespace }}/{{ $labels.deployment }} replicas mismatch",
            "        description: Deployment {{ $labels.namespace }}/{{ $labels.deployment }} has not matched the expected number of replicas for 10 minutes.",
            "",
            "    - alert: ContainerHighCPU",
            "      expr: sum by (namespace, pod, container) (rate(container_cpu_usage_seconds_total{container!=\"\"}[5m])) > 0.8",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: Container {{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }} high CPU",
            "        description: Container {{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }} is using more than 80% of CPU for more than 10 minutes.",
            "",
            "    - alert: ContainerHighMemory",
            "      expr: sum by (namespace, pod, container) (container_memory_working_set_bytes{container!=\"\"}) / sum by (namespace, pod, container) (container_spec_memory_limit_bytes{container!=\"\"}) > 0.85",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: Container {{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }} high memory",
            "        description: Container {{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }} is using more than 85% of memory limit for more than 10 minutes.",
            "",
            "    - alert: PersistentVolumeSpaceLow",
            "      expr: (kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes) * 100 < 15",
            "      for: 5m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} space low",
            "        description: Persistent volume {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} has less than 15% space remaining.",
            "",
            "  - name: rds-monitoring",
            "    interval: 60s",
            "    rules:",
            "    - alert: RDSHighCPU",
            "      expr: aws_rds_cpuutilization_average > 85",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: RDS {{ $labels.dimension_DBInstanceIdentifier }} high CPU",
            "        description: RDS instance {{ $labels.dimension_DBInstanceIdentifier }} has CPU usage above 85% for more than 10 minutes (current: {{ $value }}%).",
            "",
            "    - alert: RDSLowStorage",
            "      expr: aws_rds_free_storage_space_average / 1024 / 1024 / 1024 < 10",
            "      for: 5m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: RDS {{ $labels.dimension_DBInstanceIdentifier }} low storage",
            "        description: RDS instance {{ $labels.dimension_DBInstanceIdentifier }} has less than 10GB of free storage remaining (current: {{ $value }}GB).",
            "",
            "    - alert: RDSLowMemory",
            "      expr: aws_rds_freeable_memory_average / 1024 / 1024 / 1024 < 1",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: RDS {{ $labels.dimension_DBInstanceIdentifier }} low memory",
            "        description: RDS instance {{ $labels.dimension_DBInstanceIdentifier }} has less than 1GB of freeable memory (current: {{ $value }}GB).",
            "",
            "    - alert: RDSHighConnections",
            "      expr: aws_rds_database_connections_average > 80",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: RDS {{ $labels.dimension_DBInstanceIdentifier }} high connections",
            "        description: RDS instance {{ $labels.dimension_DBInstanceIdentifier }} has more than 80 active connections for more than 10 minutes (current: {{ $value }}).",
            "",
            "    - alert: RDSHighReadLatency",
            "      expr: aws_rds_read_latency_average > 0.1",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: RDS {{ $labels.dimension_DBInstanceIdentifier }} high read latency",
            "        description: RDS instance {{ $labels.dimension_DBInstanceIdentifier }} has read latency above 100ms for more than 10 minutes (current: {{ $value }}s).",
            "",
            "    - alert: RDSHighWriteLatency",
            "      expr: aws_rds_write_latency_average > 0.1",
            "      for: 10m",
            "      labels:",
            "        severity: warning",
            "      annotations:",
            "        summary: RDS {{ $labels.dimension_DBInstanceIdentifier }} high write latency",
            "        description: RDS instance {{ $labels.dimension_DBInstanceIdentifier }} has write latency above 100ms for more than 10 minutes (current: {{ $value }}s).",
            "RULES_EOF",

            "echo \"[Alerts] Custom alert rules configured successfully\"",
            "kubectl -n monitoring get prometheusrule custom-infrastructure-alerts",
            "",
            "echo \"[Alerts] Verifying AlertManager configuration\"",
            "kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager",
            "",
            "echo \"[Alerts] Alert configuration complete\"",
            "echo \"[Alerts] Alerts will be sent to SNS when triggered\""
          ]
        }
      }
    ]
  })

  tags = {
    Tenant   = local.global_config.tenant_name
    Env      = local.primary_env
    Managed  = "Terraform"
    Project  = "EKS-Monitoring"
    Owner    = "Ops"
  }
}

resource "aws_ssm_association" "prometheus_alerts" {
  for_each = { for k, v in module.envs : k => v if try(local.environments[k].karpenter.enabled, false) }

  name = aws_ssm_document.prometheus_alerts[0].name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-${each.key}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = each.value.eks_cluster_name
  }

  depends_on = [
    module.envs,
    aws_ssm_association.install_prometheus,
    aws_ssm_association.install_alertmanager_sns
  ]
}
