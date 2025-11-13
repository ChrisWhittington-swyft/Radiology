############################################
# SSM Document: Install YACE CloudWatch Exporter
############################################

resource "aws_ssm_document" "install_yace" {
  count         = local.karpenter_enabled ? 1 : 0
  name          = "${lower(local.effective_tenant)}-${local.primary_env}-install-yace"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install YACE CloudWatch Exporter for RDS metrics"

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
        name   = "InstallYACE"
        inputs = {
          timeoutSeconds = 600
          runCommand = [
            "#!/bin/bash",
            "set -Eeuo pipefail",
            "exec 2>&1",

            "REGION='{{Region}}'",
            "CLUSTER_NAME='{{ClusterName}}'",

            "export HOME=/root",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",

            "echo \"[YACE] Starting CloudWatch exporter installation...\"",

            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",

            "BASE_SSM_PATH=\"/eks/$CLUSTER_NAME/monitoring\"",
            "YACE_ROLE_ARN=$(aws ssm get-parameter --name \"$BASE_SSM_PATH/yace_role_arn\" --query \"Parameter.Value\" --output text || true)",

            "if [ -z \"$YACE_ROLE_ARN\" ]; then",
            "  echo \"[YACE] ERROR: Missing yace_role_arn SSM parameter\"",
            "  exit 1",
            "fi",

            "echo \"[YACE] YACE Role ARN: $YACE_ROLE_ARN\"",

            "echo \"[YACE] Creating YACE service account\"",
            "cat <<SA_EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ServiceAccount",
            "metadata:",
            "  name: yace-exporter",
            "  namespace: monitoring",
            "  annotations:",
            "    eks.amazonaws.com/role-arn: $YACE_ROLE_ARN",
            "SA_EOF",

            "echo \"[YACE] Creating YACE configuration\"",
            "cat <<CONFIG_EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ConfigMap",
            "metadata:",
            "  name: yace-config",
            "  namespace: monitoring",
            "data:",
            "  config.yml: |",
            "    discovery:",
            "      exportedTagsOnMetrics:",
            "        rds:",
            "          - Name",
            "          - Env",
            "      jobs:",
            "      - type: rds",
            "        regions:",
            "          - $REGION",
            "        searchTags:",
            "          - key: Managed",
            "            value: Terraform",
            "        metrics:",
            "          - name: CPUUtilization",
            "            statistics: [Average, Maximum]",
            "            period: 300",
            "            length: 600",
            "          - name: DatabaseConnections",
            "            statistics: [Average, Maximum]",
            "            period: 300",
            "            length: 600",
            "          - name: FreeableMemory",
            "            statistics: [Average, Minimum]",
            "            period: 300",
            "            length: 600",
            "          - name: FreeStorageSpace",
            "            statistics: [Average, Minimum]",
            "            period: 300",
            "            length: 600",
            "          - name: ReadLatency",
            "            statistics: [Average, Maximum]",
            "            period: 300",
            "            length: 600",
            "          - name: WriteLatency",
            "            statistics: [Average, Maximum]",
            "            period: 300",
            "            length: 600",
            "          - name: ReadIOPS",
            "            statistics: [Average, Maximum]",
            "            period: 300",
            "            length: 600",
            "          - name: WriteIOPS",
            "            statistics: [Average, Maximum]",
            "            period: 300",
            "            length: 600",
            "          - name: NetworkReceiveThroughput",
            "            statistics: [Average]",
            "            period: 300",
            "            length: 600",
            "          - name: NetworkTransmitThroughput",
            "            statistics: [Average]",
            "            period: 300",
            "            length: 600",
            "CONFIG_EOF",

            "echo \"[YACE] Deploying YACE exporter\"",
            "cat <<DEPLOY_EOF | kubectl apply -f -",
            "apiVersion: apps/v1",
            "kind: Deployment",
            "metadata:",
            "  name: yace-exporter",
            "  namespace: monitoring",
            "  labels:",
            "    app: yace-exporter",
            "spec:",
            "  replicas: 1",
            "  selector:",
            "    matchLabels:",
            "      app: yace-exporter",
            "  template:",
            "    metadata:",
            "      labels:",
            "        app: yace-exporter",
            "    spec:",
            "      serviceAccountName: yace-exporter",
            "      containers:",
            "      - name: yace",
            "        image: ghcr.io/nerdswords/yet-another-cloudwatch-exporter:v0.61.2",
            "        args:",
            "          - --config.file=/config/config.yml",
            "        ports:",
            "        - containerPort: 5000",
            "          name: metrics",
            "        volumeMounts:",
            "        - name: config",
            "          mountPath: /config",
            "        resources:",
            "          requests:",
            "            cpu: 100m",
            "            memory: 128Mi",
            "          limits:",
            "            cpu: 500m",
            "            memory: 512Mi",
            "      volumes:",
            "      - name: config",
            "        configMap:",
            "          name: yace-config",
            "---",
            "apiVersion: v1",
            "kind: Service",
            "metadata:",
            "  name: yace-exporter",
            "  namespace: monitoring",
            "  labels:",
            "    app: yace-exporter",
            "spec:",
            "  type: ClusterIP",
            "  ports:",
            "  - port: 5000",
            "    targetPort: 5000",
            "    protocol: TCP",
            "    name: metrics",
            "  selector:",
            "    app: yace-exporter",
            "DEPLOY_EOF",

            "echo \"[YACE] Installation complete\"",
            "kubectl -n monitoring get pods -l app=yace-exporter",
            "echo \"[YACE] Exporter accessible at: http://yace-exporter.monitoring.svc.cluster.local:5000/metrics\""
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

resource "aws_ssm_association" "install_yace" {
  count = local.karpenter_enabled ? 1 : 0
  name  = aws_ssm_document.install_yace[0].name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = module.envs[local.primary_env].eks_cluster_name
  }

  depends_on = [
    module.envs,
    aws_ssm_association.install_prometheus
  ]
}
