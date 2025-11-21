resource "aws_ssm_document" "deploy_sns_forwarder" {
  for_each = toset(local.enabled_environments)

  name          = "${lower(local.effective_tenant)}-${each.key}-deploy-sns-forwarder"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Deploy AlertManager SNS forwarder to monitoring namespace",
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
        name   = "DeploySNSForwarder",
        inputs = {
          runCommand = [
            "set -eo pipefail",
            "exec 2>&1",

            "ENV='{{ Environment }}'",
            "NS='{{ Namespace }}'",
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Deploying SNS Forwarder for environment: $${ENV}\"",

            "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
            "CLUSTER=$(aws ssm get-parameter --name /terraform/envs/$${ENV}/cluster_name --query 'Parameter.Value' --output text --region $${REGION})",
            "SNS_ROLE_ARN=$(aws ssm get-parameter --name /eks/$${CLUSTER}/monitoring/sns_forwarder_role_arn --query 'Parameter.Value' --output text --region $${REGION})",
            "SNS_TOPIC_ARN=$(aws ssm get-parameter --name /eks/$${CLUSTER}/monitoring/sns_topic_arn --query 'Parameter.Value' --output text --region $${REGION})",

            "echo \"Configuration:\"",
            "echo \"  Region: $${REGION}\"",
            "echo \"  Cluster: $${CLUSTER}\"",
            "echo \"  SNS Role ARN: $${SNS_ROLE_ARN}\"",
            "echo \"  SNS Topic ARN: $${SNS_TOPIC_ARN}\"",

            "export AWS_REGION=\"$${REGION}\" AWS_DEFAULT_REGION=\"$${REGION}\"",
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "set -u",

            "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\"",

            "kubectl get namespace \"$${NS}\" 2>/dev/null || kubectl create namespace \"$${NS}\"",

            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Applying SNS Forwarder manifests...\"",

            "cat <<EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ServiceAccount",
            "metadata:",
            "  name: alertmanager-sns-forwarder",
            "  namespace: $${NS}",
            "  annotations:",
            "    eks.amazonaws.com/role-arn: $${SNS_ROLE_ARN}",
            "EOF",

            "cat <<EOF | kubectl apply -f -",
            "apiVersion: apps/v1",
            "kind: Deployment",
            "metadata:",
            "  name: alertmanager-sns-forwarder",
            "  namespace: $${NS}",
            "  labels:",
            "    app: alertmanager-sns-forwarder",
            "spec:",
            "  replicas: 1",
            "  selector:",
            "    matchLabels:",
            "      app: alertmanager-sns-forwarder",
            "  template:",
            "    metadata:",
            "      labels:",
            "        app: alertmanager-sns-forwarder",
            "    spec:",
            "      serviceAccountName: alertmanager-sns-forwarder",
            "      containers:",
            "        - name: sns-forwarder",
            "          image: datareply/alertmanager-sns-forwarder:latest",
            "          ports:",
            "            - name: webhook",
            "              containerPort: 9087",
            "              protocol: TCP",
            "          env:",
            "            - name: AWS_REGION",
            "              value: $${REGION}",
            "            - name: SNS_TOPIC_ARN",
            "              value: $${SNS_TOPIC_ARN}",
            "          resources:",
            "            requests:",
            "              cpu: 50m",
            "              memory: 64Mi",
            "            limits:",
            "              cpu: 100m",
            "              memory: 128Mi",
            "EOF",

            "cat <<EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: Service",
            "metadata:",
            "  name: alertmanager-sns-forwarder",
            "  namespace: $${NS}",
            "  labels:",
            "    app: alertmanager-sns-forwarder",
            "spec:",
            "  type: ClusterIP",
            "  ports:",
            "    - port: 9087",
            "      targetPort: webhook",
            "      protocol: TCP",
            "      name: webhook",
            "  selector:",
            "    app: alertmanager-sns-forwarder",
            "EOF",

            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] SNS Forwarder deployment complete\"",
            "kubectl -n \"$${NS}\" get deployment alertmanager-sns-forwarder",
            "kubectl -n \"$${NS}\" get svc alertmanager-sns-forwarder",
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "deploy_sns_forwarder" {
  for_each = toset(local.enabled_environments)

  name = aws_ssm_document.deploy_sns_forwarder[each.key].name

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
    aws_ssm_document.deploy_sns_forwarder,
  ]
}
