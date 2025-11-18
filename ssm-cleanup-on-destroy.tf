# SSM Document to clean up Kubernetes resources before cluster destruction
# This removes LoadBalancer services and Ingress resources that create AWS LBs/NLBs

resource "aws_ssm_document" "cleanup_k8s_resources" {
  name            = "cleanup-k8s-resources"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Clean up Kubernetes LoadBalancer services and Ingress resources before destroy"
    parameters = {
      Region      = { type = "String", default = local.effective_region }
      ClusterName = { type = "String", default = "" }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "CleanupK8sResources"
        inputs = {
          runCommand = [
            "set -eo pipefail",
            "exec 2>&1",

            "REGION='{{ Region }}'",
            "CLUSTER='{{ ClusterName }}'",
            "echo \"[Cleanup] Starting cleanup for cluster $CLUSTER in region $REGION\"",

            # Setup kubeconfig
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",

            # Get cluster kubeconfig
            "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\" || {",
            "  echo \"[Cleanup] Failed to get kubeconfig - cluster may already be destroyed\"",
            "  exit 0",
            "}",

            # Delete all LoadBalancer services
            "echo \"[Cleanup] Deleting LoadBalancer services...\"",
            "kubectl get svc --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.spec.type==\"LoadBalancer\") | \"\\(.metadata.namespace) \\(.metadata.name)\"' | while read ns name; do",
            "  echo \"  - Deleting service $ns/$name\"",
            "  kubectl delete svc -n \"$ns\" \"$name\" --wait=false 2>/dev/null || true",
            "done",

            # Delete all Ingress resources
            "echo \"[Cleanup] Deleting Ingress resources...\"",
            "kubectl get ingress --all-namespaces -o json 2>/dev/null | jq -r '.items[] | \"\\(.metadata.namespace) \\(.metadata.name)\"' | while read ns name; do",
            "  echo \"  - Deleting ingress $ns/$name\"",
            "  kubectl delete ingress -n \"$ns\" \"$name\" --wait=false 2>/dev/null || true",
            "done",

            # Wait for AWS to process deletions
            "echo \"[Cleanup] Waiting 45 seconds for AWS to process LoadBalancer deletions...\"",
            "sleep 45",

            # Verify no LoadBalancers remain
            "REMAINING=$(kubectl get svc --all-namespaces -o json 2>/dev/null | jq '[.items[] | select(.spec.type==\"LoadBalancer\")] | length')",
            "echo \"[Cleanup] Remaining LoadBalancer services: $REMAINING\"",

            "echo \"[Cleanup] Cleanup complete for cluster $CLUSTER\""
          ]
        }
      }
    ]
  })

  tags = merge(local.tags, {
    Name = "cleanup-k8s-resources"
  })
}

# Manual cleanup association - only created when var.trigger_cleanup is true
# This is NOT meant to run automatically - you trigger it manually before destroy
variable "trigger_cleanup" {
  description = "Set to true to trigger cleanup of Kubernetes resources before destroy"
  type        = bool
  default     = false
}

resource "aws_ssm_association" "cleanup_k8s_resources" {
  for_each = var.trigger_cleanup ? module.envs : {}

  name = aws_ssm_document.cleanup_k8s_resources.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-${each.key}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = each.value.eks_cluster_name
  }

  depends_on = [module.envs]
}
