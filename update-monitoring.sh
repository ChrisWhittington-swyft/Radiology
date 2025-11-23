#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

echo "=== Updating Monitoring Configuration ==="
aws eks update-kubeconfig --region $REGION --name $CLUSTER

echo
echo "Changes:"
echo "  ✓ Removed: Node Exporter dashboard (broken)"
echo "  ✓ Removed: ArgoCD dashboard (not needed)"
echo "  ✓ Replaced: NGINX Ingress dashboard 9614 → 14314 (better compatibility)"
echo "  ✓ Added: NGINX Ingress metrics scraping"
echo

echo "Syncing ArgoCD application..."
kubectl patch application kube-prometheus-stack -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

echo
echo "Waiting for sync..."
kubectl wait --for=condition=Synced application/kube-prometheus-stack -n argocd --timeout=300s

echo
echo "=== Done! ==="
echo "The Custom folder dashboards have been cleaned up."
echo "NGINX Ingress dashboard should show data within 2-3 minutes."
