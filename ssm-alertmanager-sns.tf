############################################
# SSM Document: Install AlertManager SNS Forwarder
############################################

resource "aws_ssm_document" "install_alertmanager_sns" {
  count         = local.karpenter_enabled ? 1 : 0
  name          = "${lower(local.effective_tenant)}-${local.primary_env}-install-alertmanager-sns"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install AlertManager to SNS webhook forwarder"

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
        name   = "InstallAlertManagerSNS"
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

            "echo \"[AlertManager-SNS] Starting forwarder installation...\"",

            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",

            "BASE_SSM_PATH=\"/eks/$CLUSTER_NAME/monitoring\"",
            "SNS_FORWARDER_ROLE_ARN=$(aws ssm get-parameter --name \"$BASE_SSM_PATH/sns_forwarder_role_arn\" --query \"Parameter.Value\" --output text || true)",
            "SNS_TOPIC_ARN=$(aws ssm get-parameter --name \"$BASE_SSM_PATH/sns_topic_arn\" --query \"Parameter.Value\" --output text || true)",

            "if [ -z \"$SNS_FORWARDER_ROLE_ARN\" ] || [ -z \"$SNS_TOPIC_ARN\" ]; then",
            "  echo \"[AlertManager-SNS] ERROR: Missing SNS configuration\"",
            "  echo \"  sns_forwarder_role_arn: $SNS_FORWARDER_ROLE_ARN\"",
            "  echo \"  sns_topic_arn: $SNS_TOPIC_ARN\"",
            "  exit 1",
            "fi",

            "echo \"[AlertManager-SNS] SNS Forwarder Role: $SNS_FORWARDER_ROLE_ARN\"",
            "echo \"[AlertManager-SNS] SNS Topic: $SNS_TOPIC_ARN\"",

            "echo \"[AlertManager-SNS] Creating service account\"",
            "cat <<SA_EOF | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ServiceAccount",
            "metadata:",
            "  name: alertmanager-sns-forwarder",
            "  namespace: monitoring",
            "  annotations:",
            "    eks.amazonaws.com/role-arn: $SNS_FORWARDER_ROLE_ARN",
            "SA_EOF",

            "echo \"[AlertManager-SNS] Creating forwarder application\"",
            "cat <<'APP_EOF' | kubectl apply -f -",
            "apiVersion: v1",
            "kind: ConfigMap",
            "metadata:",
            "  name: alertmanager-sns-forwarder-script",
            "  namespace: monitoring",
            "data:",
            "  forwarder.py: |",
            "    #!/usr/bin/env python3",
            "    import json",
            "    import os",
            "    import boto3",
            "    from http.server import HTTPServer, BaseHTTPRequestHandler",
            "    from datetime import datetime",
            "    ",
            "    SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN')",
            "    AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')",
            "    ",
            "    sns_client = boto3.client('sns', region_name=AWS_REGION)",
            "    ",
            "    def format_alert(alert):",
            "        status = alert.get('status', 'unknown').upper()",
            "        labels = alert.get('labels', {})",
            "        annotations = alert.get('annotations', {})",
            "        ",
            "        alertname = labels.get('alertname', 'Unknown Alert')",
            "        severity = labels.get('severity', 'warning')",
            "        cluster = labels.get('cluster', 'unknown')",
            "        namespace = labels.get('namespace', 'N/A')",
            "        ",
            "        summary = annotations.get('summary', annotations.get('message', 'No summary'))",
            "        description = annotations.get('description', '')",
            "        ",
            "        starts_at = alert.get('startsAt', '')",
            "        ends_at = alert.get('endsAt', '')",
            "        ",
            "        message_lines = [",
            "            f'Alert: {alertname}',",
            "            f'Status: {status}',",
            "            f'Severity: {severity}',",
            "            f'Cluster: {cluster}',",
            "            f'Namespace: {namespace}',",
            "            '',",
            "            f'Summary: {summary}',",
            "        ]",
            "        ",
            "        if description:",
            "            message_lines.append(f'Description: {description}')",
            "        ",
            "        message_lines.append('')",
            "        message_lines.append(f'Started: {starts_at}')",
            "        ",
            "        if status == 'RESOLVED':",
            "            message_lines.append(f'Resolved: {ends_at}')",
            "        ",
            "        if labels:",
            "            message_lines.append('')",
            "            message_lines.append('Labels:')",
            "            for k, v in labels.items():",
            "                message_lines.append(f'  {k}: {v}')",
            "        ",
            "        return '\\n'.join(message_lines)",
            "    ",
            "    class AlertHandler(BaseHTTPRequestHandler):",
            "        def do_POST(self):",
            "            if self.path != '/alert':",
            "                self.send_response(404)",
            "                self.end_headers()",
            "                return",
            "            ",
            "            content_length = int(self.headers['Content-Length'])",
            "            post_data = self.rfile.read(content_length)",
            "            ",
            "            try:",
            "                data = json.loads(post_data.decode('utf-8'))",
            "                alerts = data.get('alerts', [])",
            "                ",
            "                print(f'Received {len(alerts)} alert(s)')",
            "                ",
            "                for alert in alerts:",
            "                    message = format_alert(alert)",
            "                    alertname = alert.get('labels', {}).get('alertname', 'Unknown')",
            "                    status = alert.get('status', 'firing')",
            "                    ",
            "                    subject = f'[{status.upper()}] {alertname}'",
            "                    ",
            "                    print(f'Publishing to SNS: {subject}')",
            "                    ",
            "                    sns_client.publish(",
            "                        TopicArn=SNS_TOPIC_ARN,",
            "                        Subject=subject[:100],",
            "                        Message=message",
            "                    )",
            "                ",
            "                self.send_response(200)",
            "                self.send_header('Content-type', 'application/json')",
            "                self.end_headers()",
            "                self.wfile.write(json.dumps({'status': 'ok'}).encode())",
            "                ",
            "            except Exception as e:",
            "                print(f'Error processing alert: {e}')",
            "                self.send_response(500)",
            "                self.end_headers()",
            "        ",
            "        def do_GET(self):",
            "            if self.path == '/health':",
            "                self.send_response(200)",
            "                self.send_header('Content-type', 'text/plain')",
            "                self.end_headers()",
            "                self.wfile.write(b'healthy')",
            "            else:",
            "                self.send_response(404)",
            "                self.end_headers()",
            "        ",
            "        def log_message(self, format, *args):",
            "            print(f'{self.address_string()} - {format % args}')",
            "    ",
            "    if __name__ == '__main__':",
            "        if not SNS_TOPIC_ARN:",
            "            print('ERROR: SNS_TOPIC_ARN environment variable not set')",
            "            exit(1)",
            "        ",
            "        print(f'Starting AlertManager SNS forwarder')",
            "        print(f'SNS Topic: {SNS_TOPIC_ARN}')",
            "        print(f'AWS Region: {AWS_REGION}')",
            "        ",
            "        server = HTTPServer(('0.0.0.0', 8080), AlertHandler)",
            "        print('Server listening on port 8080')",
            "        server.serve_forever()",
            "APP_EOF",

            "cat <<DEPLOY_EOF | kubectl apply -f -",
            "apiVersion: apps/v1",
            "kind: Deployment",
            "metadata:",
            "  name: alertmanager-sns-forwarder",
            "  namespace: monitoring",
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
            "      - name: forwarder",
            "        image: public.ecr.aws/docker/library/python:3.12-slim",
            "        command:",
            "          - /bin/bash",
            "          - -c",
            "          - |",
            "            pip install boto3 --quiet",
            "            python /app/forwarder.py",
            "        env:",
            "        - name: SNS_TOPIC_ARN",
            "          value: '$SNS_TOPIC_ARN'",
            "        - name: AWS_REGION",
            "          value: '$REGION'",
            "        ports:",
            "        - containerPort: 8080",
            "          name: http",
            "        livenessProbe:",
            "          httpGet:",
            "            path: /health",
            "            port: 8080",
            "          initialDelaySeconds: 10",
            "          periodSeconds: 30",
            "        readinessProbe:",
            "          httpGet:",
            "            path: /health",
            "            port: 8080",
            "          initialDelaySeconds: 5",
            "          periodSeconds: 10",
            "        resources:",
            "          requests:",
            "            cpu: 50m",
            "            memory: 64Mi",
            "          limits:",
            "            cpu: 200m",
            "            memory: 256Mi",
            "        volumeMounts:",
            "        - name: script",
            "          mountPath: /app",
            "      volumes:",
            "      - name: script",
            "        configMap:",
            "          name: alertmanager-sns-forwarder-script",
            "          defaultMode: 0755",
            "---",
            "apiVersion: v1",
            "kind: Service",
            "metadata:",
            "  name: alertmanager-sns-forwarder",
            "  namespace: monitoring",
            "  labels:",
            "    app: alertmanager-sns-forwarder",
            "spec:",
            "  type: ClusterIP",
            "  ports:",
            "  - port: 8080",
            "    targetPort: 8080",
            "    protocol: TCP",
            "    name: http",
            "  selector:",
            "    app: alertmanager-sns-forwarder",
            "DEPLOY_EOF",

            "echo \"[AlertManager-SNS] Installation complete\"",
            "kubectl -n monitoring get pods -l app=alertmanager-sns-forwarder",
            "echo \"[AlertManager-SNS] Forwarder accessible at: http://alertmanager-sns-forwarder.monitoring.svc.cluster.local:8080\""
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

resource "aws_ssm_association" "install_alertmanager_sns" {
  for_each = { for k, v in module.envs : k => v if try(local.environments[k].karpenter.enabled, false) }

  name = aws_ssm_document.install_alertmanager_sns[0].name

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
    aws_ssm_association.install_prometheus
  ]
}
