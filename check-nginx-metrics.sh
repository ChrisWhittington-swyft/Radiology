#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

echo "=== Checking NGINX Ingress Controller Metrics ==="
aws eks update-kubeconfig --region $REGION --name $CLUSTER

echo
echo "1. Check if nginx-ingress-controller exposes metrics:"
kubectl get svc -n ingress-nginx ingress-nginx-controller-metrics 2>/dev/null || echo "   ❌ No metrics service found"

echo
echo "2. Check if there's a ServiceMonitor for nginx:"
kubectl get servicemonitor -n ingress-nginx 2>/dev/null || echo "   ❌ No ServiceMonitor found"

echo
echo "3. Check Prometheus ServiceMonitor selector:"
kubectl get prometheus -n monitoring kube-prometheus-stack-prometheus -o jsonpath='{.spec.serviceMonitorSelector}' 2>/dev/null
echo

echo
echo "4. Test direct metrics endpoint from a controller pod:"
NGINX_POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
if [ -n "$NGINX_POD" ]; then
  echo "   Testing metrics from pod: $NGINX_POD"
  kubectl exec -n ingress-nginx $NGINX_POD -- wget -q -O - http://localhost:10254/metrics | head -20
else
  echo "   ❌ No nginx controller pod found"
fi
