# SSM document that creates Argo UI ingress

resource "aws_ssm_document" "argocd_ingress" {
  name          = "argocd-ingress"
  document_type = "Command"

content = jsonencode({
  schemaVersion = "2.2",
  description   = "Create an Ingress that routes argocd.<base_domain> to argocd-server (HTTP).",
  parameters = {
    Region      = { type = "String", default = local.effective_region }
    ClusterName = { type = "String", default = module.envs[local.primary_env].eks_cluster_name }
    ArgoHost    = { type = "String", default = local.argocd_host }
    Namespace   = { type = "String", default = "argocd" }
  },
  mainSteps = [
    {
      action = "aws:runShellScript",
      name   = "ArgoIngress",
      inputs = {
        runCommand = [
          "set -eo pipefail",
          "exec 2>&1",

          "REGION='{{ Region }}'",
          "CLUSTER='{{ ClusterName }}'",
          "HOST='{{ ArgoHost }}'",
          "NS='{{ Namespace }}'",
          "echo \"[ArgoIngress] Region=$${REGION} Cluster=$${CLUSTER} Host=$${HOST} Namespace=$${NS}\"",

          # Fallback Region
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
  for_each = module.envs

  name = aws_ssm_document.argocd_ingress.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-${each.key}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = each.value.eks_cluster_name
    ArgoHost    = "argocd.${local.base_domain}"
    Namespace   = "argocd"
  }

  depends_on = [
    module.envs,
    aws_ssm_association.install_argocd_now
    #aws_route53_record.argocd
  ]
}
