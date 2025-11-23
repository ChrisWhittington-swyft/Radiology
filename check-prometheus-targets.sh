#!/bin/bash
REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

aws eks update-kubeconfig --region $REGION --name $CLUSTER

echo "=== Checking what's being scraped by Prometheus ==="
echo
echo "1. Check if node-exporter is running:"
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter

echo
echo "2. Check if nginx-ingress metrics are available:"
kubectl get svc -n ingress-nginx

echo
echo "3. Check ArgoCD metrics service:"
kubectl get svc -n argocd -l app.kubernetes.io/name=argocd-metrics

echo
echo "4. View Prometheus targets (port-forward and check manually):"
echo "   kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo "   Then visit: http://localhost:9090/targets"
