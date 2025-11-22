#!/bin/bash
# Troubleshooting script for YACE CloudWatch Exporter

set -e

echo "=== YACE Troubleshooting Script ==="
echo

# Get cluster name
REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')
CLUSTER=$(aws ssm get-parameter --name /terraform/envs/dev/cluster_name --query 'Parameter.Value' --output text --region ${REGION})

echo "Region: ${REGION}"
echo "Cluster: ${CLUSTER}"
echo

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER}" --alias "${CLUSTER}"
echo

# Check if YACE is deployed
echo "=== Checking YACE Deployment Status ==="
kubectl -n monitoring get deployment yace-exporter -o wide || echo "YACE deployment not found!"
echo

# Check YACE pods
echo "=== YACE Pod Status ==="
kubectl -n monitoring get pods -l app=yace-exporter -o wide
echo

# Check YACE pod logs
echo "=== YACE Pod Logs (last 50 lines) ==="
YACE_POD=$(kubectl -n monitoring get pods -l app=yace-exporter -o jsonpath='{.items[0].metadata.name}')
if [ -n "${YACE_POD}" ]; then
  kubectl -n monitoring logs ${YACE_POD} --tail=50
else
  echo "No YACE pod found!"
fi
echo

# Check YACE service
echo "=== YACE Service ==="
kubectl -n monitoring get svc yace-exporter
echo

# Check YACE metrics endpoint
echo "=== Testing YACE Metrics Endpoint ==="
if [ -n "${YACE_POD}" ]; then
  echo "Attempting to curl metrics from YACE pod..."
  kubectl -n monitoring exec ${YACE_POD} -- wget -qO- http://localhost:5000/metrics | head -20
  echo "..."
  echo
  echo "Searching for RDS metrics:"
  kubectl -n monitoring exec ${YACE_POD} -- wget -qO- http://localhost:5000/metrics | grep -i "aws_rds" | head -10 || echo "No RDS metrics found"
  echo
  echo "Searching for ElastiCache metrics:"
  kubectl -n monitoring exec ${YACE_POD} -- wget -qO- http://localhost:5000/metrics | grep -i "aws_elasticache" | head -10 || echo "No ElastiCache metrics found"
else
  echo "Cannot test - no pod found!"
fi
echo

# Check YACE ConfigMap
echo "=== YACE ConfigMap ==="
kubectl -n monitoring get configmap yace-config -o yaml
echo

# Check if Prometheus is scraping YACE
echo "=== Checking Prometheus Scrape Config ==="
kubectl -n monitoring get prometheus -o yaml | grep -A 10 "yace-cloudwatch" || echo "YACE scrape config not found in Prometheus"
echo

# Check Prometheus targets
echo "=== Prometheus Targets (requires port-forward) ==="
echo "To check Prometheus targets manually, run:"
echo "  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
echo "  Then visit: http://localhost:9090/targets"
echo

# Check YACE IAM role
echo "=== YACE Service Account ==="
kubectl -n monitoring get sa yace-exporter -o yaml
echo

echo "=== Troubleshooting Complete ==="
echo
echo "Common issues:"
echo "1. YACE pod not running - check logs above"
echo "2. No metrics - check IAM role has CloudWatch read permissions"
echo "3. Prometheus not scraping - verify additionalScrapeConfigs in monitoring.yaml"
echo "4. Wrong region/tags - verify YACE config matches your RDS/Redis tags"
