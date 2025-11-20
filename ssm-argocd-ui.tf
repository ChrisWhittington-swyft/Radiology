# SSM document that creates Argo UI ingress

resource "aws_ssm_document" "argocd_ingress" {
  for_each = toset(local.enabled_environments)

  name          = "${lower(local.effective_tenant)}-${each.key}-argocd-ingress"
  document_type = "Command"

content = jsonencode({
  schemaVersion = "2.2",
  description   = "Create an Ingress that routes argocd.<base_domain> to argocd-server (HTTP) - per environment.",
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
      name   = "ArgoIngress",
      inputs = {
        runCommand = [
          "set -eo pipefail",
          "exec 2>&1",

          "ENV='{{ Environment }}'",
          "NS='{{ Namespace }}'",
          "echo \"[ArgoIngress] Environment: $ENV Namespace: $NS\"",

          # Lookup environment-specific values from SSM
          "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
          "CLUSTER=$(aws ssm get-parameter --name /terraform/envs/$ENV/cluster_name --query 'Parameter.Value' --output text --region $REGION)",
          "HOST=$(aws ssm get-parameter --name /terraform/envs/$ENV/argocd/host --query 'Parameter.Value' --output text --region $REGION)",

          "echo \"Configuration loaded for $ENV\"",
          "echo \"  Cluster: $CLUSTER\"",
          "echo \"  ArgoCD Host: $HOST\"",
          "echo \"[ArgoIngress] Region=$${REGION} Cluster=$${CLUSTER} Host=$${HOST} Namespace=$${NS}\"",

          # Kubeconfig env
          "export HOME=/root",
          "mkdir -p /root/.kube",
          "export KUBECONFIG=/root/.kube/config",
          "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",
          "set -u",

          # Sanity + kubeconfig
          "aws sts get-caller-identity 1>/dev/null",
          "aws eks describe-cluster --name \"$CLUSTER\" --region \"$REGION\" 1>/dev/null",
          "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\"",

          # Ensure argocd-server service exists (if this runs standalone)
          "for i in $(seq 1 60); do",
          "  kubectl -n \"$NS\" get svc argocd-server >/dev/null 2>&1 && break || true",
          "  echo \"[ArgoIngress] Waiting for argocd-server svc ($i/60)\"; sleep 5",
          "done",

          # Create Ingress
          "cat > /tmp/argocd-ingress.yaml <<'EOF'",
          "apiVersion: networking.k8s.io/v1",
          "kind: Ingress",
          "metadata:",
          "  name: argocd",
          "  namespace: argocd",
          "  annotations:",
          "    kubernetes.io/ingress.class: nginx",
          "spec:",
          "  rules:",
          "    - host: ARGO_HOST_PLACEHOLDER",
          "      http:",
          "        paths:",
          "          - path: /",
          "            pathType: Prefix",
          "            backend:",
          "              service:",
          "                name: argocd-server",
          "                port:",
          "                  number: 80",
          "EOF",
          "sed -i \"s/ARGO_HOST_PLACEHOLDER/$${HOST}/g\" /tmp/argocd-ingress.yaml",
          "kubectl apply -f /tmp/argocd-ingress.yaml",
          "kubectl -n \"$NS\" get ingress argocd -o wide || true"
        ]
      }
    }
  ]
})
}

resource "aws_ssm_association" "argocd_ingress_now" {
  for_each = toset(local.enabled_environments)

  name = aws_ssm_document.argocd_ingress[each.key].name

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
    aws_ssm_document.argocd_ingress,
    aws_ssm_association.install_argocd_now,
    aws_ssm_parameter.env_cluster_names,
    aws_ssm_parameter.env_argocd_hosts,
  ]
}
