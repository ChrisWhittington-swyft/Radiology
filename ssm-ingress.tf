# SSM document that bootstraps ingress-nginx per environment
resource "aws_ssm_document" "bootstrap_ingress" {
  for_each = toset(local.enabled_environments)

  name          = "${lower(local.effective_tenant)}-${each.key}-bootstrap-ingress-and-app"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Install/upgrade ingress-nginx (NLB+ACM) and deploy ingress - per environment",
    parameters = {
      Environment = {
        type        = "String"
        description = "Environment name (prod, dev, etc.)"
      }
      Namespace = {
        type    = "String"
        default = "ingress-nginx"
      }
    },
    mainSteps = [
      {
        action = "aws:runShellScript",
        name   = "BootstrapIngressAndApp",
        inputs = {
          runCommand = [
            "set -eo pipefail",
            "exec 2>&1",

            # Variables
            "ENV='{{ Environment }}'",
            "NS='{{ Namespace }}'",
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Starting bootstrap for environment: $${ENV}\"",

            # Lookup environment-specific values from SSM Parameter Store
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Looking up environment configuration from SSM...\"",
            "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
            "CLUSTER=$(aws ssm get-parameter --name /terraform/envs/$${ENV}/cluster_name --query 'Parameter.Value' --output text --region $${REGION})",
            "ACM_ARN=$(aws ssm get-parameter --name /terraform/shared/acm_arn --query 'Parameter.Value' --output text --region $${REGION})",
            "APP_HOST=$(aws ssm get-parameter --name /terraform/envs/$${ENV}/app_host --query 'Parameter.Value' --output text --region $${REGION})",
            "INGRESS_NLB_NAME=$(aws ssm get-parameter --name /terraform/envs/$${ENV}/ingress_nlb_name --query 'Parameter.Value' --output text --region $${REGION})",

            "echo \"Configuration loaded:\"",
            "echo \"  Region: $${REGION}\"",
            "echo \"  Cluster: $${CLUSTER}\"",
            "echo \"  App Host: $${APP_HOST}\"",
            "echo \"  NLB Name: $${INGRESS_NLB_NAME}\"",
            "echo \"  Namespace: $${NS}\"",

            "export AWS_REGION=\"$${REGION}\" AWS_DEFAULT_REGION=\"$${REGION}\"",

            # Setup kubeconfig
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "set -u",

            # Sanity checks
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Verifying credentials and cluster access...\"",
            "aws sts get-caller-identity",
            "aws eks describe-cluster --name \"$CLUSTER\" --region \"$REGION\" --query 'cluster.name' --output text",
            "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\"",

            # Diagnostics
            "kubectl version --client --output=yaml || true",
            "kubectl get nodes --request-timeout=10s || echo 'Warning: Could not list nodes'",

            # Ensure namespace exists
            "kubectl get namespace \"$${NS}\" 2>/dev/null || kubectl create namespace \"$${NS}\"",

            # Helm repo
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Setting up Helm repository...\"",
            "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>&1 || true",
            "helm repo update 2>&1",

            # Chart selector
            "CHART=\"ingress-nginx/ingress-nginx\"",
            "CHART_VERSION='4.11.3'",

            # Upgrade in place or install once
            "helm upgrade --install ingress-nginx \"$${CHART}\" --version \"$${CHART_VERSION}\" \\",
            "  --namespace \"$${NS}\" \\",
            "  --create-namespace \\",
            "  --timeout 10m \\",
            "  --wait \\",
            "  --reuse-values \\",
            "  --set podSecurityPolicy.enabled=false \\",
            "  --set controller.replicaCount=2 \\",
            "  --set controller.service.type=LoadBalancer \\",
            "  --set controller.service.externalTrafficPolicy=Local \\",
            "  --set-string controller.service.annotations.'service\\.beta\\.kubernetes\\.io/aws-load-balancer-type'='nlb' \\",
            "  --set-string controller.service.annotations.'service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme'='internet-facing' \\",
            "  --set-string controller.service.annotations.'service\\.beta\\.kubernetes\\.io/aws-load-balancer-cross-zone-load-balancing-enabled'='true' \\",
            "  --set-string controller.service.annotations.'service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-cert'=\"$${ACM_ARN}\" \\",
            "  --set-string controller.service.annotations.'service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-ports'='443' \\",
            "  --set-string controller.service.annotations.'service\\.beta\\.kubernetes\\.io/aws-load-balancer-backend-protocol'='http' \\",
            "  --set-string controller.service.annotations.'service\\.beta\\.kubernetes\\.io/aws-load-balancer-name'=\"$${INGRESS_NLB_NAME}\" \\",
            "  --set controller.service.targetPorts.http=http \\",
            "  --set controller.service.targetPorts.https=http",

            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Helm upgrade/install completed\"",

            # Verify service was (still) present
            "kubectl -n \"$${NS}\" get svc ingress-nginx-controller -o wide",

            # Wait for NLB hostname (up to 10 minutes)
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for NLB hostname (max 10 minutes)...\"",
            "FOUND=false",
            "for i in $(seq 1 60); do",
            "  LB=$(kubectl -n \"$${NS}\" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)",
            "  if [ -n \"$${LB}\" ]; then",
            "    echo \"[$(date '+%Y-%m-%d %H:%M:%S')] NLB Hostname: $${LB}\"",
            "    FOUND=true",
            "    break",
            "  fi",
            "  echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Waiting... ($i/60)\"",
            "  sleep 10",
            "done",
            "if [ \"$${FOUND}\" = \"false\" ]; then",
            "  echo \"ERROR: NLB not provisioned after 10 minutes\"",
            "  kubectl -n \"$${NS}\" describe svc ingress-nginx-controller || true",
            "  kubectl -n \"$${NS}\" get pods || true",
            "  kubectl -n \"$${NS}\" get events --sort-by='.lastTimestamp' | tail -20 || true",
            "  exit 1",
            "fi",

            # Final status
            "echo \"\"",
            "echo \"========================================\"",
            "echo \"FINAL STATUS - Environment: $${ENV}\"",
            "echo \"========================================\"",
            "kubectl -n \"$${NS}\" get svc ingress-nginx-controller -o wide",
            "echo \"\"",
            "echo \"Service Annotations:\"",
            "kubectl -n \"$${NS}\" get svc ingress-nginx-controller -o jsonpath='{.metadata.annotations}' | python3 -m json.tool 2>/dev/null || kubectl -n \"$${NS}\" get svc ingress-nginx-controller -o jsonpath='{.metadata.annotations}'",
            "echo \"\"",
            "echo \"NLB Hostname:\"",
            "LB=$(kubectl -n \"$${NS}\" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)",
            "echo \"$${LB}\"",
            "echo \"\"",
            "echo \"App URL: https://$${APP_HOST}\"",
          ]
        }
      }
    ]
  })
}

# Per-environment associations
resource "aws_ssm_association" "bootstrap_ingress_now" {
  for_each = toset(local.enabled_environments)

  name = aws_ssm_document.bootstrap_ingress[each.key].name

  # Target by Environment tag
  targets {
    key    = "tag:Environment"
    values = [each.key]
  }

  parameters = {
    Environment = each.key
    Namespace   = "ingress-nginx"
  }

  depends_on = [
    module.envs,
    aws_ssm_document.bootstrap_ingress,
    aws_acm_certificate.wildcard,
    aws_acm_certificate_validation.wildcard,
    aws_ssm_parameter.env_cluster_names,
    aws_ssm_parameter.env_app_hosts,
    aws_ssm_parameter.env_ingress_nlb_names,
    aws_ssm_parameter.shared_acm_arn,
  ]
}
