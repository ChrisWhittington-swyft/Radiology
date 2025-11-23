#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

echo "=== Checking Prometheus Targets for YACE ==="
aws eks update-kubeconfig --region $REGION --name $CLUSTER

echo
echo "=== 1. YACE ServiceMonitor ==="
kubectl get servicemonitor yace-exporter -n monitoring -o yaml

echo
echo "=== 2. YACE Service Endpoints ==="
kubectl get endpoints yace-exporter -n monitoring

echo
echo "=== 3. Check if Prometheus is scraping YACE ==="
echo "Fetching Prometheus targets..."
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF_PID=$!
sleep 5

curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job | contains("yace")) | "Job: \(.labels.job)\nState: \(.health)\nLast Scrape: \(.lastScrape)\nError: \(.lastError // "none")\n"'

kill $PF_PID 2>/dev/null || true

echo
echo "=== 4. Query YACE metrics from Prometheus ==="
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF_PID=$!
sleep 5

echo "RDS Metrics:"
curl -s 'http://localhost:9090/api/v1/query?query=aws_rds_cpuutilization_average' | jq -r '.data.result[] | "  \(.metric.name): \(.value[1])"'

echo
echo "ElastiCache Metrics:"
curl -s 'http://localhost:9090/api/v1/query?query=aws_elasticache_cpuutilization_average' | jq -r '.data.result[] | "  \(.metric.name): \(.value[1])"'

kill $PF_PID 2>/dev/null || true

echo
echo "=== Done ==="
