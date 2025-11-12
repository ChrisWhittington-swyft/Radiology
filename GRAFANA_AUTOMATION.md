# Grafana Automation Setup

## Overview
This document outlines the automated Grafana configuration that has been added to the infrastructure.

## Components Added

### 1. Datasource Configuration (via Grafana API)
Automatically creates and configures the AMP datasource in Grafana:
- **Method**: Grafana HTTP API (AWS provider doesn't support datasource resources)
- **Type**: Prometheus
- **Authentication**: SigV4 (IAM-based)
- **Default**: Set as default datasource
- **URL**: Automatically uses AMP workspace endpoint
- **Execution**: Via SSM document on bastion

### 2. Dashboard Import Automation (`ssm-grafana-dashboards.tf`)
SSM document that automatically imports essential Kubernetes dashboards:

#### Dashboards Imported:
1. **Kubernetes Cluster Monitoring** (ID: 7249)
   - Overall cluster health and resource usage

2. **Kubernetes Pod Monitoring** (ID: 6417)
   - Per-pod metrics and resource consumption

3. **Node Exporter Full** (ID: 1860)
   - Detailed node-level system metrics

4. **Kubernetes API Server** (ID: 12006)
   - API server performance and health

5. **Kubernetes System API Server** (ID: 15761)
   - System-level API metrics

6. **Kubernetes Deployment/StatefulSet/DaemonSet** (ID: 8588)
   - Workload-specific metrics

#### Custom Folder:
- Creates "EKS Monitoring" folder for custom dashboards

### 3. SSM Association
- **Target**: Bastion host (tagged with bastion name)
- **Execution**: Runs after Prometheus installation
- **Output**: Stored in S3 bucket under `grafana-dashboards/` prefix
- **Parameters**:
  - Grafana Workspace ID (from Terraform output)
  - AMP Workspace Endpoint (from Terraform output)
  - AWS Region

## How It Works

### Terraform Apply Sequence:
1. **Creates AMP workspace** → Amazon Managed Prometheus
2. **Creates AMG workspace** → Amazon Managed Grafana
3. **Creates SSM document** → Datasource + Dashboard automation script
4. **Creates SSM association** → Triggers configuration on bastion

### Configuration Process:
1. SSM association runs on bastion after Prometheus installation
2. Script creates temporary Grafana API key (1-hour TTL)
3. **Configures AMP datasource** via Grafana API:
   - Sets up Prometheus datasource pointing to AMP
   - Enables SigV4 authentication
   - Sets as default datasource
4. **Downloads and imports dashboards**:
   - Fetches dashboard JSON from Grafana.com for each dashboard
   - Wraps dashboards with correct datasource mappings
   - Imports via Grafana API
5. Creates "EKS Monitoring" folder for custom dashboards

## Deployment

### Apply Changes:
```bash
terraform apply -auto-approve
```

### Monitor Progress:
```bash
# Check SSM association status
aws ssm list-associations --region us-east-1

# View execution output
aws ssm list-command-invocations \
  --details \
  --region us-east-1 | jq '.CommandInvocations[0]'

# Or check S3 logs
aws s3 ls s3://<ssm-logs-bucket>/grafana-dashboards/ --recursive
```

### Access Grafana:
```bash
# Get Grafana URL from Terraform output
terraform output grafana_workspace_url
```

## Configuration Options

### Enable/Disable Monitoring:
In `instances.tf`, per environment:
```hcl
environments = {
  prod = {
    # ... other config ...
    monitoring = {
      enabled = true  # Set to false to disable
    }
  }
}
```

### Customize Dashboards:
Edit `ssm-grafana-dashboards.tf` and modify the `import_dashboard` function calls:
```bash
# Add new dashboard import
import_dashboard "<DASHBOARD_ID>" "<DASHBOARD_NAME>"
```

Find dashboard IDs at: https://grafana.com/grafana/dashboards/

## Troubleshooting

### Dashboard Import Fails:
1. Check SSM association execution logs in S3
2. Verify Grafana API key creation succeeded
3. Ensure bastion has internet access to Grafana.com

### Datasource Not Working:
1. Verify IAM role has AMP query permissions
2. Check Grafana workspace role ARN is correct
3. Test AMP endpoint connectivity

### No Data in Dashboards:
1. Verify Prometheus is writing to AMP:
   ```bash
   kubectl --context <context> -n monitoring logs prometheus-prometheus-kube-prometheus-prometheus-0
   ```
2. Check remote_write configuration in Prometheus
3. Verify IRSA is working (AWS env vars in pod)

## Architecture

```
┌─────────────────┐
│   EKS Cluster   │
│                 │
│  ┌──────────┐   │      ┌─────────────────┐
│  │Prometheus│───┼─────→│ AMP Workspace   │
│  │  (IRSA)  │   │      │  (Remote Write) │
│  └──────────┘   │      └────────┬────────┘
└─────────────────┘               │
                                  │ SigV4
                                  │ Query
                                  ↓
                         ┌─────────────────┐
                         │ AMG Workspace   │
                         │  (Datasource:   │
                         │   AMP via IAM)  │
                         └─────────────────┘
                                  ↑
                                  │ Import
                         ┌────────┴────────┐
                         │ SSM Document    │
                         │  (on Bastion)   │
                         └─────────────────┘
```

## Benefits

1. **Zero Manual Configuration**: Entire monitoring stack deployed via Terraform
2. **Repeatable**: Same setup across all environments
3. **Secure**: IAM-based auth, no API keys stored long-term
4. **Scalable**: AMP handles metric storage and querying
5. **Managed**: No Prometheus or Grafana infrastructure to maintain
6. **Observable**: Pre-configured dashboards for immediate insights

## Next Steps

After deployment:
1. Access Grafana workspace URL
2. Configure AWS SSO users for Grafana access
3. Review imported dashboards
4. Create custom dashboards in "EKS Monitoring" folder
5. Set up alerting rules in Grafana
