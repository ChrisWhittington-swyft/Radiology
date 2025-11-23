#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

echo "=== Checking all YACE metrics in Prometheus ==="
aws eks update-kubeconfig --region $REGION --name $CLUSTER

kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
PF_PID=$!
sleep 5

echo
echo "=== All aws_* metrics available ==="
curl -s 'http://localhost:9090/api/v1/label/__name__/values' | jq -r '.data[] | select(startswith("aws_"))' | sort

echo
echo "=== Sample RDS metrics with labels ==="
curl -s 'http://localhost:9090/api/v1/query?query=aws_rds_cpuutilization_average' | jq -r '.data.result[0].metric'

echo
echo "=== Sample ElastiCache metrics with labels ==="
curl -s 'http://localhost:9090/api/v1/query?query=aws_elasticache_cpuutilization_average' | jq -r '.data.result[0].metric'

kill $PF_PID 2>/dev/null || true

echo
echo "=== Done ==="
