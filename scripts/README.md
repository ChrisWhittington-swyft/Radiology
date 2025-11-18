# Cleanup Scripts

## Quick Reference

### Normal Destroy Process

```bash
# 1. Clean up Kubernetes resources FIRST
./scripts/cleanup-before-destroy.sh vytalmed-prod-eks

# 2. Then destroy infrastructure
terraform destroy
```

### Already Stuck with Errors?

```bash
# Use the force cleanup script with your VPC ID from error message
./scripts/force-cleanup-stuck-vpc.sh vpc-00de1af3d48f7c390

# Wait 2-3 minutes, then retry
terraform destroy
```

## Scripts

### cleanup-before-destroy.sh

**Purpose:** Run BEFORE terraform destroy to clean up Kubernetes-managed resources

**Usage:**
```bash
./scripts/cleanup-before-destroy.sh <cluster-name>
```

**What it does:**
- Deletes all LoadBalancer services (removes NLBs/ALBs)
- Deletes all Ingress resources
- Waits for AWS to finish cleanup
- Verifies cleanup completed

**When to use:**
- Before every `terraform destroy`
- As part of your destroy workflow
- When following best practices

### force-cleanup-stuck-vpc.sh

**Purpose:** Emergency cleanup when VPC/subnets are stuck

**Usage:**
```bash
./scripts/force-cleanup-stuck-vpc.sh <vpc-id>
```

**What it does:**
- Deletes all LoadBalancers in VPC
- Deletes NAT Gateways
- Releases Elastic IPs
- Deletes available ENIs
- Checks ACM certificate usage

**When to use:**
- After terraform destroy failed with dependency errors
- When subnets won't delete
- When IGW won't detach
- When ACM cert shows "in use"

## Examples

### Example 1: Clean Destroy

```bash
#!/usr/bin/env bash
# My destroy workflow

# Cleanup K8s resources
./scripts/cleanup-before-destroy.sh vytalmed-prod-eks

# Destroy infrastructure
terraform destroy -auto-approve
```

### Example 2: Fix Stuck Destroy

```bash
# Got this error:
# Error: deleting EC2 Subnet (subnet-01631fd30a2ccd71c): has dependencies

# Extract VPC ID from terraform state or AWS console
VPC_ID="vpc-00de1af3d48f7c390"

# Force cleanup
./scripts/force-cleanup-stuck-vpc.sh "$VPC_ID"

# Wait for AWS
sleep 120

# Retry destroy
terraform destroy
```

### Example 3: Multi-Environment Cleanup

```bash
# Clean both environments before destroying account
for env in prod dev; do
  echo "Cleaning $env..."
  ./scripts/cleanup-before-destroy.sh "vytalmed-${env}-eks"
done

# Now destroy everything
terraform destroy
```

## Troubleshooting

### Script says "cluster may not exist"

**Cause:** Cluster already deleted

**Solution:** Use force-cleanup-stuck-vpc.sh instead

### Script fails with "AWS CLI not found"

**Cause:** AWS CLI not installed or not in PATH

**Solution:**
```bash
# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

### Script fails with "kubectl not found"

**Cause:** kubectl not installed

**Solution:**
```bash
# Use force-cleanup-stuck-vpc.sh instead (doesn't need kubectl)
./scripts/force-cleanup-stuck-vpc.sh vpc-xxxxx
```

### "Permission denied" when running script

**Cause:** Script not executable

**Solution:**
```bash
chmod +x scripts/*.sh
```

## Advanced: Automated Destroy Pipeline

```bash
#!/usr/bin/env bash
# destroy-pipeline.sh - Full automated destroy

set -euo pipefail

CLUSTER_NAME="${1:-vytalmed-prod-eks}"
VPC_ID="${2:-}"

echo "=== Phase 1: Kubernetes Cleanup ==="
if aws eks describe-cluster --name "$CLUSTER_NAME" --region us-east-1 &>/dev/null; then
  ./scripts/cleanup-before-destroy.sh "$CLUSTER_NAME"
else
  echo "Cluster not found, skipping K8s cleanup"
fi

echo ""
echo "=== Phase 2: Terraform Destroy ==="
terraform destroy -auto-approve || {
  echo ""
  echo "Terraform destroy failed. Attempting VPC cleanup..."

  if [ -n "$VPC_ID" ]; then
    ./scripts/force-cleanup-stuck-vpc.sh "$VPC_ID"
    sleep 120
    echo "Retrying terraform destroy..."
    terraform destroy -auto-approve
  else
    echo "ERROR: VPC_ID not provided. Cannot run force cleanup."
    exit 1
  fi
}

echo ""
echo "=== Destroy Complete ==="
```

## Integration with CI/CD

```yaml
# GitHub Actions example
- name: Cleanup Kubernetes Resources
  run: |
    ./scripts/cleanup-before-destroy.sh vytalmed-${{ env.ENV }}-eks
  continue-on-error: true

- name: Terraform Destroy
  run: terraform destroy -auto-approve

- name: Force Cleanup on Failure
  if: failure()
  run: |
    ./scripts/force-cleanup-stuck-vpc.sh ${{ env.VPC_ID }}
    sleep 120
    terraform destroy -auto-approve
```
