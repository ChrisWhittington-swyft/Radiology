############################################
# SSM Document: Install Self-Hosted Monitoring Stack
############################################

resource "aws_ssm_document" "install_prometheus" {
  count         = local.karpenter_enabled ? 1 : 0
  name          = "${lower(local.effective_tenant)}-${local.primary_env}-install-prometheus"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install self-hosted Prometheus, Grafana, AlertManager, and YACE CloudWatch exporter"

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
        name   = "InstallMonitoringStack"
        inputs = {
          timeoutSeconds = 900
          runCommand = [
            "#!/bin/bash",
            "set -Eeuo pipefail",
            "exec 2>&1",

            "REGION='{{Region}}'",
            "CLUSTER_NAME='{{ClusterName}}'",

            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",

            "echo \"[Monitoring] Starting self-hosted monitoring stack installation...\"",

            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",
            "kubectl get ns kube-system 1>/dev/null 2>&1 || { echo \"[Monitoring] ERROR: cannot reach cluster\"; exit 1; }",

            "echo \"[Monitoring] Creating monitoring namespace\"",
            "kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -",

            "echo \"[Monitoring] Adding Helm repositories\"",
            "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true",
            "helm repo update",

            "echo \"[Monitoring] Creating kube-prometheus-stack values file\"",
            "cat > /tmp/prometheus-values.yaml <<'HELM_EOF'",
            "prometheus:",
            "  prometheusSpec:",
            "    retention: 30d",
            "    retentionSize: 45GB",
            "    resources:",
            "      requests:",
            "        cpu: 500m",
            "        memory: 2Gi",
            "      limits:",
            "        cpu: 2000m",
            "        memory: 4Gi",
            "    storageSpec:",
            "      volumeClaimTemplate:",
            "        spec:",
            "          accessModes: ['ReadWriteOnce']",
            "          resources:",
            "            requests:",
            "              storage: 50Gi",
            "    additionalScrapeConfigs:",
            "    - job_name: yace-cloudwatch",
            "      static_configs:",
            "      - targets:",
            "        - yace-exporter.monitoring.svc.cluster.local:5000",
            "",
            "grafana:",
            "  enabled: true",
            "  adminPassword: changeme-$(openssl rand -hex 12)",
            "  persistence:",
            "    enabled: true",
            "    size: 10Gi",
            "  grafana.ini:",
            "    server:",
            "      root_url: https://monitoring.yourdomain.com",
            "    auth.anonymous:",
            "      enabled: false",
            "    security:",
            "      allow_embedding: false",
            "  service:",
            "    type: ClusterIP",
            "  ingress:",
            "    enabled: false",
            "",
            "alertmanager:",
            "  enabled: true",
            "  config:",
            "    global:",
            "      resolve_timeout: 5m",
            "    route:",
            "      group_by: ['alertname', 'cluster', 'service']",
            "      group_wait: 10s",
            "      group_interval: 10s",
            "      repeat_interval: 12h",
            "      receiver: 'sns-webhook'",
            "    receivers:",
            "    - name: 'sns-webhook'",
            "      webhook_configs:",
            "      - url: 'http://alertmanager-sns-forwarder.monitoring.svc.cluster.local:8080/alert'",
            "        send_resolved: true",
            "",
            "defaultRules:",
            "  create: true",
            "  rules:",
            "    alertmanager: true",
            "    etcd: false",
            "    configReloaders: true",
            "    general: true",
            "    k8s: true",
            "    kubeApiserverAvailability: true",
            "    kubeApiserverSlos: false",
            "    kubelet: true",
            "    kubeProxy: false",
            "    kubePrometheusGeneral: true",
            "    kubePrometheusNodeRecording: true",
            "    kubernetesApps: true",
            "    kubernetesResources: true",
            "    kubernetesStorage: true",
            "    kubernetesSystem: true",
            "    kubeScheduler: false",
            "    kubeStateMetrics: true",
            "    network: true",
            "    node: true",
            "    nodeExporterAlerting: true",
            "    nodeExporterRecording: true",
            "    prometheus: true",
            "    prometheusOperator: true",
            "HELM_EOF",

            "echo \"[Monitoring] Installing kube-prometheus-stack\"",
            "helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \\",
            "  --namespace monitoring \\",
            "  --values /tmp/prometheus-values.yaml \\",
            "  --wait --timeout 15m",

            "GRAFANA_PASSWORD=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d)",
            "echo \"[Monitoring] Grafana admin password: $GRAFANA_PASSWORD\"",
            "echo \"[Monitoring] Storing password in SSM\"",
            "aws ssm put-parameter --name \"/eks/$CLUSTER_NAME/monitoring/grafana_password\" --value \"$GRAFANA_PASSWORD\" --type \"SecureString\" --overwrite || true",

            "echo \"[Monitoring] kube-prometheus-stack installation complete\"",
            "kubectl -n monitoring get pods"
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

resource "aws_ssm_association" "install_prometheus" {
  for_each = { for k, v in module.envs : k => v if try(local.environments[k].karpenter.enabled, false) }

  name = aws_ssm_document.install_prometheus[0].name

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
    aws_ssm_association.install_karpenter_now
  ]
}
