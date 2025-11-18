# SSM document that installs Argo CD

resource "aws_ssm_document" "install_argocd" {
  name          = "install-argocd"
  document_type = "Command"

content = jsonencode({
  schemaVersion = "2.2",
  description   = "Install Argo CD via Helm (HTTP service; TLS terminates at NLB).",
  parameters = {
    Region      = { type = "String", default = local.effective_region }
    ClusterName = { type = "String", default = "" }
    Namespace   = { type = "String", default = "argocd" }
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
          "REGION='{{ Region }}'",
          "CLUSTER='{{ ClusterName }}'",
          "NS='{{ Namespace }}'",
          "echo \"[ArgoCD] Region=$${REGION} Cluster=$${CLUSTER} Namespace=$${NS}\"",

          # Fallback Region if blank/'-'
          "[ -z \"$REGION\" ] || [ \"$REGION\" = \"-\" ] && {",
          "  TOKEN=$(curl -sS -X PUT \"http://169.254.169.254/latest/api/token\" -H \"X-aws-ec2-metadata-token-ttl-seconds: 60\" || true)",
          "  REGION=$(curl -sS -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/placement/region || echo \"\")",
          "}",
          "[ -z \"$REGION\" ] && REGION=\"us-east-1\"",

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

          # Helm install/upgrade
          "helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true",
          "helm repo update >/dev/null 2>&1 || true",
          "helm upgrade --install argocd argo/argo-cd \\",
          "  --namespace \"$NS\" --create-namespace \\",
          "  --set server.insecure=true \\",
          "  --set server.service.type=ClusterIP \\",
          "  --set configs.params.\"server\\.insecure\"=true \\",
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
          "echo \"[ArgoCD] Wrote/updated $${PARAM_NAME}\""
        ]
      }
    }
  ]
})
}


resource "aws_ssm_association" "install_argocd_now" {
  for_each = module.envs

  name = aws_ssm_document.install_argocd.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-${each.key}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = each.value.eks_cluster_name
    Namespace   = "argocd"
  }

  depends_on = [module.envs]
}
