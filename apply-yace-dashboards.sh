#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

echo "=== Updating YACE Dashboards ==="
aws eks update-kubeconfig --region $REGION --name $CLUSTER

# Create ConfigMap from the dashboard files
kubectl create configmap grafana-dashboard-rds-aurora \
  --from-file=rds-aurora-yace.json=grafana-rds-dashboard.json \
  --namespace=monitoring \
  --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard="1" --dry-run=client -o yaml | \
  kubectl annotate --local -f - k8s-sidecar-target-directory="/tmp/dashboards/AWS Services" --dry-run=client -o yaml | \
  kubectl apply -f -

echo
echo "Restarting Grafana to reload dashboard..."
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana
kubectl rollout status deployment -n monitoring kube-prometheus-stack-grafana --timeout=120s

echo
echo "=== Done! New RDS metrics should appear in ~2 minutes ==="
echo "New panels added:"
echo "  - ACU Utilization"
echo "  - Serverless Database Capacity"
echo "  - Deadlocks"
echo "  - Network Throughput (Receive/Transmit)"
echo "  - Storage Throughput (Read/Write)"
echo "  - Storage IOPS (Read/Write)"
echo "  - Disk Queue Depth"
echo "  - Buffer Cache Hit Ratio"
