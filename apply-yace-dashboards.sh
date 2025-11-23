#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

echo "=== Applying YACE-compatible dashboards ==="
aws eks update-kubeconfig --region $REGION --name $CLUSTER

echo
echo "1. Applying ConfigMaps with custom dashboards..."
kubectl apply -f ria-application-main/clusters/dev/infra/aws-dashboards-configmap.yaml

echo
echo "2. Verify ConfigMaps are created..."
kubectl get configmaps -n monitoring -l grafana_dashboard=1

echo
echo "3. Restart Grafana to pick up new dashboards..."
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana

echo
echo "4. Wait for Grafana to be ready..."
kubectl rollout status deployment -n monitoring kube-prometheus-stack-grafana --timeout=120s

echo
echo "=== Done! ==="
echo
echo "The following dashboards are now available in Grafana:"
echo "  - AWS RDS Aurora (YACE)"
echo "  - AWS ElastiCache Redis (YACE)"
echo
echo "Access Grafana at: https://grafana-dev.nymbl.host"
echo "Navigate to: Dashboards > Browse > AWS Services folder"
