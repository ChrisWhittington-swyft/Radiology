#!/bin/bash
set -e

REGION="${1:-us-east-1}"
CLUSTER="${2:-ria-dev-eks}"

echo "=== Debugging YACE ServiceMonitor Configuration ==="
aws eks update-kubeconfig --region $REGION --name $CLUSTER

echo
echo "=== 1. YACE Service Labels ==="
kubectl get svc yace-exporter -n monitoring -o jsonpath='{.metadata.labels}' | jq '.'

echo
echo "=== 2. ServiceMonitor Selector ==="
kubectl get servicemonitor yace-exporter -n monitoring -o jsonpath='{.spec.selector.matchLabels}' | jq '.'

echo
echo "=== 3. Check if labels match ==="
SVC_LABELS=$(kubectl get svc yace-exporter -n monitoring -o json | jq -r '.metadata.labels.app // "NOT_FOUND"')
SM_SELECTOR=$(kubectl get servicemonitor yace-exporter -n monitoring -o json | jq -r '.spec.selector.matchLabels.app // "NOT_FOUND"')

echo "Service app label: $SVC_LABELS"
echo "ServiceMonitor selector: $SM_SELECTOR"

if [ "$SVC_LABELS" = "$SM_SELECTOR" ]; then
  echo "✓ Labels MATCH"
else
  echo "✗ Labels DO NOT MATCH - Prometheus won't discover this target!"
fi

echo
echo "=== 4. Check Prometheus ServiceMonitor selector ==="
echo "Checking if Prometheus is configured to discover ServiceMonitors with 'release: kube-prometheus-stack' label..."
kubectl get prometheus -n monitoring kube-prometheus-stack-prometheus -o jsonpath='{.spec.serviceMonitorSelector}' | jq '.'

echo
echo "=== 5. ServiceMonitor has required label? ==="
SM_RELEASE_LABEL=$(kubectl get servicemonitor yace-exporter -n monitoring -o json | jq -r '.metadata.labels.release // "NOT_FOUND"')
echo "ServiceMonitor release label: $SM_RELEASE_LABEL"

if [ "$SM_RELEASE_LABEL" = "kube-prometheus-stack" ]; then
  echo "✓ Has release label"
else
  echo "✗ Missing release label - Prometheus won't discover this ServiceMonitor!"
fi

echo
echo "=== 6. All ServiceMonitors Prometheus is watching ==="
kubectl get servicemonitor -n monitoring -l release=kube-prometheus-stack --no-headers | wc -l
echo "Total ServiceMonitors with release=kube-prometheus-stack label"

echo
echo "=== 7. Check YACE endpoints ==="
kubectl get endpoints yace-exporter -n monitoring -o json | jq '.subsets[].addresses[]?.ip'

echo
echo "=== Done ==="
