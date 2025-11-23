#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"
NS="monitoring"

echo "=== YACE Debug Script ==="
echo "Region: $REGION"
echo "Cluster: $CLUSTER"
echo

# Update kubeconfig
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --alias "$CLUSTER" 2>/dev/null

echo "=== 1. YACE Pod Status ==="
kubectl -n $NS get pods -l app=yace-exporter -o wide
echo

echo "=== 2. YACE Pod Events ==="
YACE_POD=$(kubectl -n $NS get pods -l app=yace-exporter -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$YACE_POD" ]; then
  kubectl -n $NS describe pod $YACE_POD | grep -A 20 "Events:"
else
  echo "No YACE pod found!"
fi
echo

echo "=== 3. YACE Full Logs ==="
if [ -n "$YACE_POD" ]; then
  kubectl -n $NS logs $YACE_POD --tail=100
else
  echo "No YACE pod found!"
fi
echo

echo "=== 4. YACE ConfigMap ==="
kubectl -n $NS get configmap yace-config -o yaml
echo

echo "=== 5. YACE ServiceAccount ==="
kubectl -n $NS get sa yace-exporter -o yaml
echo

echo "=== 6. Testing Metrics Endpoint ==="
if [ -n "$YACE_POD" ]; then
  echo "Raw metrics (first 30 lines):"
  kubectl -n $NS exec $YACE_POD -- wget -qO- http://localhost:5000/metrics 2>/dev/null | head -30
  echo "..."
  echo
  echo "RDS metrics count:"
  kubectl -n $NS exec $YACE_POD -- wget -qO- http://localhost:5000/metrics 2>/dev/null | grep -c "aws_rds" || echo "0"
  echo
  echo "ElastiCache metrics count:"
  kubectl -n $NS exec $YACE_POD -- wget -qO- http://localhost:5000/metrics 2>/dev/null | grep -c "aws_elasticache" || echo "0"
  echo
  echo "Sample RDS metrics:"
  kubectl -n $NS exec $YACE_POD -- wget -qO- http://localhost:5000/metrics 2>/dev/null | grep "aws_rds" | head -5
  echo
  echo "Sample ElastiCache metrics:"
  kubectl -n $NS exec $YACE_POD -- wget -qO- http://localhost:5000/metrics 2>/dev/null | grep "aws_elasticache" | head -5
else
  echo "Cannot test - no pod found!"
fi
echo

echo "=== 7. Prometheus ServiceMonitor/Scrape Config ==="
kubectl -n $NS get servicemonitor -o yaml 2>/dev/null || echo "No ServiceMonitors found"
echo
kubectl -n $NS get prometheus -o jsonpath='{.items[0].spec.additionalScrapeConfigs}' 2>/dev/null || echo "No additional scrape configs"
echo

echo "=== Done ==="
