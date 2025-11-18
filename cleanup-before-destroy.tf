# Cleanup resources before destroy to handle AWS/K8s dependencies
# This ensures LoadBalancers and ENIs created by EKS are cleaned up before VPC/subnet destruction

# Local exec to clean up Kubernetes resources before destroying EKS
resource "null_resource" "cleanup_k8s_resources" {
  for_each = module.envs

  triggers = {
    cluster_name = each.value.eks_cluster_name
    region       = local.effective_region
    bastion_id   = try(each.value.bastion_id, "none")
  }

  # This runs ONLY on destroy
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Cleaning up Kubernetes resources for cluster ${self.triggers.cluster_name}..."

      # Set AWS region
      export AWS_DEFAULT_REGION="${self.triggers.region}"

      # Try to get kubeconfig (may fail if cluster already destroyed, that's ok)
      aws eks update-kubeconfig --name "${self.triggers.cluster_name}" --region "${self.triggers.region}" 2>/dev/null || true

      # Delete all services of type LoadBalancer (these create AWS NLBs/ALBs)
      echo "Deleting LoadBalancer services..."
      kubectl get svc --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read ns name; do
          kubectl delete svc -n "$ns" "$name" --wait=false 2>/dev/null || true
        done

      # Delete ingress resources (may have associated LoadBalancers)
      echo "Deleting ingress resources..."
      kubectl delete ingress --all --all-namespaces --wait=false 2>/dev/null || true

      # Wait a bit for AWS to process deletions
      echo "Waiting 30s for AWS cleanup..."
      sleep 30

      echo "Cleanup complete for ${self.triggers.cluster_name}"
    EOT

    on_failure = continue
  }

  depends_on = [module.envs]
}

# Force VPC resources to wait for EKS cleanup
resource "time_sleep" "wait_for_k8s_cleanup" {
  depends_on = [
    null_resource.cleanup_k8s_resources,
  ]

  destroy_duration = "60s"

  triggers = {
    # Recreate this when any EKS cluster changes
    clusters = jsonencode([for k, v in module.envs : v.eks_cluster_name])
  }
}

# Add explicit depends_on to VPC resources
# This ensures they wait for cleanup before attempting deletion
