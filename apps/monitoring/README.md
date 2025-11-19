# On-Cluster Monitoring Stack

This directory contains manifests for deploying a self-hosted monitoring stack on EKS:

- **Prometheus** - Metrics collection and alerting
- **YACE (Yet Another CloudWatch Exporter)** - AWS CloudWatch metrics export
- **AlertManager** - Alert routing
- **AlertManager SNS Forwarder** - Forwards alerts to SNS/Slack

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌────────────────┐
│  Prometheus │────▶│ AlertManager │────▶│  SNS Forwarder │────▶ SNS/Slack
└─────────────┘     └──────────────┘     └────────────────┘
       │
       │ scrapes
       ▼
┌─────────────┐
│    YACE     │────▶ AWS CloudWatch APIs
└─────────────┘
```

## Configuration Highlights

### Conservative Scraping
- Global scrape interval: **60s** (not 15s!)
- CloudWatch scrape interval: **120s** (AWS APIs are slow)
- Metric relabeling to drop high-cardinality metrics
- Retention: 30 days / 45GB

### Resource Limits
All components have conservative CPU/memory limits to prevent cluster overload.

## Setup Instructions

### 1. Replace Placeholders

Before deploying, you need to replace IAM role ARNs and SNS topic ARN:

**Files to update:**
- `yace-serviceaccount.yaml` - Replace `PLACEHOLDER_YACE_ROLE_ARN`
- `alertmanager-sns-serviceaccount.yaml` - Replace `PLACEHOLDER_SNS_FORWARDER_ROLE_ARN`
- `alertmanager-sns-deployment.yaml` - Replace `PLACEHOLDER_SNS_TOPIC_ARN`

**Get the values from Terraform outputs or SSM:**
```bash
# YACE Role ARN
aws ssm get-parameter --name "/eks/<cluster-name>/monitoring/yace_role_arn" --query Parameter.Value --output text

# SNS Forwarder Role ARN
aws ssm get-parameter --name "/eks/<cluster-name>/monitoring/sns_forwarder_role_arn" --query Parameter.Value --output text

# SNS Topic ARN
aws ssm get-parameter --name "/eks/<cluster-name>/monitoring/sns_topic_arn" --query Parameter.Value --output text
```

### 2. Deploy via ArgoCD

The monitoring stack is deployed via two ArgoCD Applications in `/clusters/default/monitoring.yaml`:

1. **monitoring-manifests** - Deploys YAML resources (YACE, SNS forwarder, namespace)
2. **monitoring-prometheus** - Deploys Prometheus Helm chart with custom values

ArgoCD will automatically sync and deploy when you push changes to the repository.

### 3. Access Prometheus UI

Forward the Prometheus port:
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
```

Then access at: http://localhost:9090

## Updating Configuration

### Update Prometheus Scrape Configs
Edit the inline values in `/clusters/default/monitoring.yaml` under `monitoring-prometheus` > `helm.values`.

### Update YACE CloudWatch Metrics
Edit `yace-config.yaml` to add/remove AWS services or metrics.

### Update AlertManager Rules
Edit the inline values in `/clusters/default/monitoring.yaml` under `alertmanager.config`.

ArgoCD will automatically apply changes on the next sync (within ~3 minutes).

## Cost Optimization

This setup is designed to be cost-effective:

- **No AWS Managed Prometheus** ($0.30/month per metric)
- **No AWS Managed Grafana** ($9/month per user)
- **Minimal CloudWatch API calls** (YACE scrapes at 120s intervals)
- **Aggressive metric filtering** (drops unnecessary high-cardinality metrics)

Expected cost: **~$5-10/month** (just EBS storage for Prometheus data)

## Troubleshooting

### YACE not scraping
Check IRSA setup:
```bash
kubectl describe sa -n monitoring yace-exporter
kubectl logs -n monitoring deployment/yace-exporter
```

### AlertManager not forwarding to SNS
Check SNS forwarder:
```bash
kubectl logs -n monitoring deployment/alertmanager-sns-forwarder
```

### High memory usage
Reduce scrape frequency or add more aggressive metric filtering in Prometheus config.
