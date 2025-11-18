#!/usr/bin/env bash
set -euo pipefail

# Cleanup script to run BEFORE terraform destroy
# This removes Kubernetes-created AWS resources that block VPC/subnet deletion

REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${1:-}"

if [ -z "$CLUSTER_NAME" ]; then
  echo "Usage: $0 <cluster-name>"
  echo "Example: $0 vytalmed-prod-eks"
  exit 1
fi

echo "=========================================="
echo "Cleaning up Kubernetes resources"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "=========================================="

# Update kubeconfig
echo "Getting kubeconfig for cluster..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" || {
  echo "ERROR: Failed to get kubeconfig. Cluster may not exist or you lack permissions."
  exit 1
}

# Delete all LoadBalancer services (these create AWS NLBs/ALBs)
echo ""
echo "Deleting LoadBalancer services..."
kubectl get svc --all-namespaces -o json | \
  jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' | \
  while read -r ns name; do
    echo "  - Deleting service $ns/$name"
    kubectl delete svc -n "$ns" "$name" --timeout=60s || true
  done

# Delete all Ingress resources
echo ""
echo "Deleting Ingress resources..."
kubectl get ingress --all-namespaces -o json | \
  jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
  while read -r ns name; do
    echo "  - Deleting ingress $ns/$name"
    kubectl delete ingress -n "$ns" "$name" --timeout=60s || true
  done

# Wait for AWS to delete the LoadBalancers
echo ""
echo "Waiting 60 seconds for AWS to delete LoadBalancers..."
sleep 60

# Verify cleanup
REMAINING=$(kubectl get svc --all-namespaces -o json | jq '[.items[] | select(.spec.type=="LoadBalancer")] | length')
echo ""
echo "Remaining LoadBalancer services: $REMAINING"

if [ "$REMAINING" -gt 0 ]; then
  echo "WARNING: Some LoadBalancer services still exist. Waiting another 30s..."
  sleep 30
fi

echo ""
echo "=========================================="
echo "Cleanup complete!"
echo "You can now run: terraform destroy"
echo "=========================================="
