resource "aws_ssm_document" "deploy_yace" {
  for_each = toset(local.enabled_environments)

  name          = "${lower(local.effective_tenant)}-${each.key}-deploy-yace"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Deploy YACE CloudWatch exporter to monitoring namespace",
    parameters = {
      Environment = {
        type        = "String"
        description = "Environment name (prod, dev, etc.)"
      }
      Namespace = {
        type    = "String"
        default = "monitoring"
      }
    },
    mainSteps = [
      {
        action = "aws:runShellScript",
        name   = "DeployYACE",
        inputs = {
          runCommand = [
            "set -eo pipefail",
            "exec 2>&1",

            "ENV='{{ Environment }}'",
            "NS='{{ Namespace }}'",
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Deploying YACE for environment: $${ENV}\"",

            "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
            "CLUSTER=$(aws ssm get-parameter --name /terraform/envs/$${ENV}/cluster_name --query 'Parameter.Value' --output text --region $${REGION})",
            "YACE_ROLE_ARN=$(aws ssm get-parameter --name /eks/$${CLUSTER}/monitoring/yace_role_arn --query 'Parameter.Value' --output text --region $${REGION})",

            "echo \"Configuration:\"",
            "echo \"  Region: $${REGION}\"",
            "echo \"  Cluster: $${CLUSTER}\"",
            "echo \"  YACE Role ARN: $${YACE_ROLE_ARN}\"",

            "export AWS_REGION=\"$${REGION}\" AWS_DEFAULT_REGION=\"$${REGION}\"",
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "set -u",

            "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\"",

            "kubectl get namespace \"$${NS}\" 2>/dev/null || kubectl create namespace \"$${NS}\"",

            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Applying YACE manifests...\"",

            "cat <<EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ServiceAccount",
            "metadata:",
            "  name: yace-exporter",
            "  namespace: $${NS}",
            "  annotations:",
            "    eks.amazonaws.com/role-arn: $${YACE_ROLE_ARN}",
            "EOF",

            "cat <<EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ConfigMap",
            "metadata:",
            "  name: yace-config",
            "  namespace: $${NS}",
            "data:",
            "  config.yml: |",
            "    apiVersion: v1alpha1",
            "    sts-region: $${REGION}",
            "    discovery:",
            "      exportedTagsOnMetrics:",
            "        rds:",
            "          - Name",
            "          - Env",
            "        kafka:",
            "          - Name",
            "          - Env",
            "      jobs:",
            "        - type: rds",
            "          regions:",
            "            - $${REGION}",
            "          searchTags:",
            "            - key: Env",
            "              value: $${ENV}",
            "          metrics:",
            "            - name: CPUUtilization",
            "              statistics: [Average, Maximum]",
            "              period: 300",
            "              length: 600",
            "            - name: DatabaseConnections",
            "              statistics: [Average, Maximum]",
            "              period: 300",
            "              length: 600",
            "            - name: FreeableMemory",
            "              statistics: [Average]",
            "              period: 300",
            "              length: 600",
            "            - name: FreeStorageSpace",
            "              statistics: [Average]",
            "              period: 300",
            "              length: 600",
            "            - name: ReadLatency",
            "              statistics: [Average]",
            "              period: 300",
            "              length: 600",
            "            - name: WriteLatency",
            "              statistics: [Average]",
            "              period: 300",
            "              length: 600",
            "        - type: kafka",
            "          regions:",
            "            - $${REGION}",
            "          searchTags:",
            "            - key: Env",
            "              value: $${ENV}",
            "          metrics:",
            "            - name: CpuUser",
            "              statistics: [Average]",
            "              period: 300",
            "              length: 600",
            "            - name: MemoryUsed",
            "              statistics: [Average]",
            "              period: 300",
            "              length: 600",
            "            - name: KafkaDataLogsDiskUsed",
            "              statistics: [Average]",
            "              period: 300",
            "              length: 600",
            "            - name: BytesInPerSec",
            "              statistics: [Sum]",
            "              period: 300",
            "              length: 600",
            "            - name: BytesOutPerSec",
            "              statistics: [Sum]",
            "              period: 300",
            "              length: 600",
            "    static:",
            "      - namespace: AWS/ElastiCache",
            "        name: ria-$${ENV}-redis",
            "        regions:",
            "          - $${REGION}",
            "        dimensions:",
            "          - name: CacheClusterId",
            "            value: ria-$${ENV}-redis-001",
            "        customTags:",
            "          - key: Env",
            "            value: $${ENV}",
            "          - key: Name",
            "            value: ria-$${ENV}-redis",
            "        metrics:",
            "          - name: CPUUtilization",
            "            statistics: [Average]",
            "            period: 300",
            "            length: 600",
            "          - name: NetworkBytesIn",
            "            statistics: [Sum]",
            "            period: 300",
            "            length: 600",
            "          - name: NetworkBytesOut",
            "            statistics: [Sum]",
            "            period: 300",
            "            length: 600",
            "          - name: CurrConnections",
            "            statistics: [Average]",
            "            period: 300",
            "            length: 600",
            "EOF",

            "cat <<EOF | kubectl apply -f -",
            "apiVersion: apps/v1",
            "kind: Deployment",
            "metadata:",
            "  name: yace-exporter",
            "  namespace: $${NS}",
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
            "        - name: yace",
            "          image: ghcr.io/nerdswords/yet-another-cloudwatch-exporter:v0.58.0",
            "          ports:",
            "            - name: metrics",
            "              containerPort: 5000",
            "              protocol: TCP",
            "          env:",
            "            - name: AWS_REGION",
            "              value: $${REGION}",
            "          volumeMounts:",
            "            - name: config",
            "              mountPath: /tmp/config.yml",
            "              subPath: config.yml",
            "          resources:",
            "            requests:",
            "              cpu: 100m",
            "              memory: 256Mi",
            "            limits:",
            "              cpu: 500m",
            "              memory: 512Mi",
            "      volumes:",
            "        - name: config",
            "          configMap:",
            "            name: yace-config",
            "EOF",

            "cat <<EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: Service",
            "metadata:",
            "  name: yace-exporter",
            "  namespace: $${NS}",
            "  labels:",
            "    app: yace-exporter",
            "spec:",
            "  type: ClusterIP",
            "  ports:",
            "    - port: 5000",
            "      targetPort: metrics",
            "      protocol: TCP",
            "      name: metrics",
            "  selector:",
            "    app: yace-exporter",
            "EOF",

            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] YACE deployment complete\"",
            "kubectl -n \"$${NS}\" get deployment yace-exporter",
            "kubectl -n \"$${NS}\" get svc yace-exporter",
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "deploy_yace" {
  for_each = toset(local.enabled_environments)

  name = aws_ssm_document.deploy_yace[each.key].name

  targets {
    key    = "tag:Environment"
    values = [each.key]
  }

  parameters = {
    Environment = each.key
    Namespace   = "monitoring"
  }

  depends_on = [
    module.envs,
    aws_ssm_document.deploy_yace,
  ]
}
