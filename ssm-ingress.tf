# SSM document that bootstraps ingress-nginx and a sample app
resource "aws_ssm_document" "bootstrap_ingress" {
  name          = "bootstrap-ingress-and-app"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Install/upgrade ingress-nginx (NLB+ACM) and deploy ingress",
    parameters = {
      Region       = { type = "String",  default = local.global_config.region }
      ClusterName  = { type = "String",  default = module.envs[local.primary_env].eks_cluster_name }
      AcmArn       = { type = "String",  default = aws_acm_certificate.wildcard.arn }
      AppHost      = { type = "String",  default = local.app_host }
      Namespace    = { type = "String",  default = "ingress-nginx" }
      IngressNlbName = { type = "String", default = local.ingress_nlb_name }
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
            "REGION='{{ Region }}'",
            "CLUSTER='{{ ClusterName }}'",
            "ACM_ARN='{{ AcmArn }}'",
            "APP_HOST='{{ AppHost }}'",
            "NS='{{ Namespace }}'",
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Starting bootstrap process\"",
            "echo \"Region: $${REGION}  Cluster: $${CLUSTER}  Namespace: $${NS}\"",
            "export AWS_REGION=\"$${REGION}\" AWS_DEFAULT_REGION=\"$${REGION}\"",
            "INGRESS_NLB_NAME='{{ IngressNlbName }}'",
            "echo \"Using fixed NLB name: $${INGRESS_NLB_NAME}\"",

            # Fallback region detection
            "[ -z \"$REGION\" ] || [ \"$REGION\" = \"-\" ] && {",
            "  TOKEN=$(curl -sS -X PUT \"http://169.254.169.254/latest/api/token\" -H \"X-aws-ec2-metadata-token-ttl-seconds: 60\" || true)",
            "  REGION=$(curl -sS -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/placement/region || echo \"\")",
            "}",
            "[ -z \"$REGION\" ] && REGION=\"us-east-1\"",

            # Setup kubeconfig
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",
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

            # Persist NLB hostname to SSM Parameter Store for Terraform to read
            "PARAM_NAME=\"/eks/$${CLUSTER}/ingress_nlb_hostname\"",
            "if [ -n \"$${LB}\" ]; then",
            "  aws ssm put-parameter --name \"$${PARAM_NAME}\" --type String --overwrite --value \"$${LB}\"",
            "  echo \"Wrote SSM parameter: $${PARAM_NAME} = $${LB}\"",
            "else",
            "  echo \"WARN: LB hostname empty; skipping SSM put-parameter\"",
            "fi",

            # Final status
            "echo \"\"",
            "echo \"========================================\"",
            "echo \"FINAL STATUS\"",
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

resource "aws_ssm_association" "bootstrap_ingress_now" {
  name = aws_ssm_document.bootstrap_ingress.name

  # 👇 Target by tag so replacement instances get picked up automatically
  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = module.envs[local.primary_env].eks_cluster_name
    AcmArn      = aws_acm_certificate.wildcard.arn
    AppHost     = local.app_host
    Namespace   = "ingress-nginx"
  }

   #lifecycle {
   #  ignore_changes = [parameters]
   #}

  depends_on = [
    module.envs,
    aws_ssm_document.bootstrap_ingress,
    aws_acm_certificate.wildcard,
    aws_acm_certificate_validation.wildcard,
  ]
}
