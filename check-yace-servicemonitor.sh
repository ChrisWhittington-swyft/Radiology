#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

echo "=== Checking YACE ServiceMonitor ==="
aws eks update-kubeconfig --region $REGION --name $CLUSTER

echo
echo "=== Looking for YACE ServiceMonitor ==="
kubectl get servicemonitor -n monitoring -l app=yace-exporter -o yaml

echo
echo "=== YACE Service Labels ==="
kubectl get svc yace-exporter -n monitoring --show-labels

echo
echo "=== All ServiceMonitors in monitoring namespace ==="
kubectl get servicemonitor -n monitoring -o wide
