# SSM document that installs Argo CD per environment

resource "aws_ssm_document" "install_argocd" {
  for_each = toset(local.enabled_environments)

  name          = "${lower(local.effective_tenant)}-${each.key}-install-argocd"
  document_type = "Command"

content = jsonencode({
  schemaVersion = "2.2",
  description   = "Install Argo CD via Helm (HTTP service; TLS terminates at NLB) - per environment.",
  parameters = {
    Environment = {
      type        = "String"
      description = "Environment name (prod, dev, etc.)"
    }
    Namespace = {
      type    = "String"
      default = "argocd"
    }
  },
  mainSteps = [
    {
      action = "aws:runShellScript",
      name   = "InstallArgoCD",
      inputs = {
        runCommand = [
          # be strict (enable -u after we set vars)
          "set -eo pipefail",
          "exec 2>&1",

          # Params
          "ENV='{{ Environment }}'",
          "NS='{{ Namespace }}'",
          "echo \"[ArgoCD] Starting installation for environment: $${ENV}\"",

          # Lookup environment-specific values from SSM Parameter Store
          "echo \"[ArgoCD] Looking up environment configuration from SSM...\"",
          "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
          "CLUSTER=$(aws ssm get-parameter --name /terraform/envs/$${ENV}/cluster_name --query 'Parameter.Value' --output text --region $${REGION})",
          "HOST=$(aws ssm get-parameter --name /terraform/envs/$${ENV}/argocd/host --query 'Parameter.Value' --output text --region $${REGION})",

          "echo \"Configuration loaded:\"",
          "echo \"  Region: $${REGION}\"",
          "echo \"  Cluster: $${CLUSTER}\"",
          "echo \"  Namespace: $${NS}\"",
          "echo \"  ArgoCD Host: $${HOST}\"",

          # Kubeconfig env
          "export HOME=/root",
          "mkdir -p /root/.kube",
          "export KUBECONFIG=/root/.kube/config",
          "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",
          "set -u",

          # Sanity checks
          "aws sts get-caller-identity 1>/dev/null",
          "aws eks describe-cluster --name \"$CLUSTER\" --region \"$REGION\" 1>/dev/null",

          # Build kubeconfig
          "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\"",

          # Ensure namespace exists
          "kubectl get ns \"$NS\" 2>/dev/null || kubectl create ns \"$NS\"",

          # Helm install/upgrade - create values file with proper URL
          "helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true",
          "helm repo update >/dev/null 2>&1 || true",
          "cat > /tmp/argocd-values.yaml <<EOF",
          "global:",
          "  domain: $HOST",
          "configs:",
          "  cm:",
          "    url: https://$HOST",
          "  params:",
          "    server.insecure: 'true'",
          "redis:",
          "  enabled: true",
          "server:",
          "  insecure: true",
          "  service:",
          "    type: ClusterIP",
          "  extraArgs:",
          "    - --insecure",
          "EOF",
          "helm upgrade --install argocd argo/argo-cd \\",
          "  --namespace \"$NS\" --create-namespace \\",
          "  --values /tmp/argocd-values.yaml \\",
          "  --wait --timeout 10m",

          # Wait for argocd-server Service to exist (avoid race with next step)
          "echo \"[ArgoCD] Waiting for argocd-server service...\"",
          "for i in $(seq 1 60); do",
          "  kubectl -n \"$NS\" get svc argocd-server >/dev/null 2>&1 && break || true",
          "  echo \"...still waiting ($i/60)\"; sleep 5",
          "done",
          "kubectl -n \"$NS\" get svc argocd-server",


          #Wait + SSM write initial admin pw
          "echo \"[ArgoCD] Waiting for initial admin password...\"",
          "PASS=\"\"",
          "for i in $(seq 1 60); do",
          "  PASS=$(kubectl -n \"$NS\" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)",
          "  [ -n \"$PASS\" ] && break",
          "  echo \"...still waiting for password ($i/60)\"; sleep 5",
          "done",
          "[ -z \"$PASS\" ] && echo \"[ArgoCD] ERROR: Could not read initial admin password.\" && exit 1",
          "PARAM_NAME=\"/eks/$${CLUSTER}/argocd/admin_password\"",
          "echo \"[ArgoCD] Writing admin password to SSM Parameter Store at $${PARAM_NAME} ...\"",
          "aws ssm put-parameter --region \"$REGION\" --name \"$${PARAM_NAME}\" --type SecureString --overwrite --value \"$PASS\"",
          "echo \"[ArgoCD] Wrote/updated $${PARAM_NAME}\"",
          "echo \"[ArgoCD] Installation completed for environment: $${ENV}\""
        ]
      }
    }
  ]
})
}

# Per-environment associations
resource "aws_ssm_association" "install_argocd_now" {
  for_each = toset(local.enabled_environments)

  name = aws_ssm_document.install_argocd[each.key].name

  # Target by Environment tag
  targets {
    key    = "tag:Environment"
    values = [each.key]
  }

  parameters = {
    Environment = each.key
    Namespace   = "argocd"
  }

  depends_on = [
    module.envs,
    aws_ssm_parameter.env_cluster_names,
    aws_ssm_parameter.env_argocd_hosts,
  ]
}
