#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

echo "=== Cleaning up old dashboards ==="
aws eks update-kubeconfig --region $REGION --name $CLUSTER

echo "1. Delete ALL existing dashboard ConfigMaps..."
kubectl delete configmap -n monitoring grafana-dashboard-rds-aurora --ignore-not-found
kubectl delete configmap -n monitoring grafana-dashboard-elasticache --ignore-not-found

echo "2. Wait a moment..."
sleep 3

echo "3. Re-apply fresh ConfigMaps..."
kubectl apply -f ria-application-main/clusters/dev/monitoring-infra/aws-dashboards-configmap.yaml

echo "4. Restart Grafana to reload dashboards..."
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana

echo "5. Wait for Grafana..."
kubectl rollout status deployment -n monitoring kube-prometheus-stack-grafana --timeout=120s

echo
echo "=== Done! ==="
echo "Only the 2 YACE dashboards should now appear in AWS Services folder"
