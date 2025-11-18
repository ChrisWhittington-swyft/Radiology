# Safe Terraform Destroy Guide

## The Problem

When destroying this infrastructure, you'll encounter dependency errors:

```
Error: deleting EC2 Subnet: has dependencies and cannot be deleted
Error: deleting EC2 Internet Gateway: has some mapped public address(es)
Error: deleting ACM Certificate: is in use
```

**Root Cause:** Kubernetes creates AWS resources (LoadBalancers, ENIs) that Terraform doesn't know about. These block VPC/subnet deletion.

## Solution: Cleanup Before Destroy

### Option 1: Manual Script (Recommended)

Run the cleanup script for each environment BEFORE `terraform destroy`:

```bash
# For prod environment
./scripts/cleanup-before-destroy.sh vytalmed-prod-eks

# For dev environment (if exists)
./scripts/cleanup-before-destroy.sh vytalmed-dev-eks

# Wait for completion, then:
terraform destroy
```

The script:
- Deletes all LoadBalancer services (removes NLBs/ALBs)
- Deletes all Ingress resources
- Waits for AWS to finish cleanup
- Verifies no LoadBalancers remain

### Option 2: Manual Cleanup via kubectl

If you prefer manual control:

```bash
# Set cluster context
aws eks update-kubeconfig --name vytalmed-prod-eks --region us-east-1

# Delete all LoadBalancer services
kubectl get svc --all-namespaces -o wide | grep LoadBalancer
kubectl delete svc -n ingress-nginx ingress-nginx-controller
kubectl delete svc -n argocd argocd-server
# ... delete any others

# Delete all Ingress resources
kubectl delete ingress --all --all-namespaces

# Wait 60 seconds for AWS
sleep 60

# Proceed with terraform destroy
terraform destroy
```

### Option 3: AWS Console Cleanup

If the cluster is already gone:

1. **EC2 Console** → **Load Balancers**
   - Delete all NLBs/ALBs with tag `kubernetes.io/cluster/vytalmed-*-eks`

2. **EC2 Console** → **Network Interfaces**
   - Find ENIs in your subnets with "EKS" description
   - Delete them (may need to wait for cluster deletion first)

3. **VPC Console** → **Elastic IPs**
   - Release any EIPs associated with the VPC

4. Try `terraform destroy` again

## Automatic Cleanup (Optional)

The infrastructure includes automatic cleanup resources in `cleanup-before-destroy.tf`, but this requires:
- Terraform running where it can execute `kubectl`
- Valid AWS credentials
- Cluster still accessible

To enable automatic cleanup:

```hcl
# In your terraform.tfvars or CLI
trigger_cleanup = true
```

Then apply once to trigger cleanup, wait 2 minutes, then destroy.

## Destroy Order (What Terraform Tries To Do)

With proper dependencies, Terraform will:

1. **Trigger cleanup** (if enabled)
2. **Delete EKS add-ons** (managed by terraform-aws-modules/eks)
3. **Delete EKS cluster** (waits for all nodes to drain)
4. **Wait for K8s cleanup** (60s sleep)
5. **Delete ACM certificate** (now unused)
6. **Delete VPC/subnets** (now no dependencies)

## Common Issues

### "Subnet has dependencies"

**Cause:** ENIs from EKS nodes or LoadBalancers still exist

**Fix:**
```bash
# Find ENIs in the subnet
aws ec2 describe-network-interfaces \
  --filters Name=subnet-id,Values=subnet-01631fd30a2ccd71c \
  --region us-east-1

# If they're attached to LoadBalancers, delete those first
# If they're attached to terminated instances, wait 5 minutes and retry
```

### "Internet Gateway has mapped public addresses"

**Cause:** NAT Gateways or LoadBalancers with public IPs still exist

**Fix:**
```bash
# Check for NAT Gateways
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=vpc-00de1af3d48f7c390"

# Check for LoadBalancers
aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[] | select(.VpcId=="vpc-00de1af3d48f7c390")'
aws elb describe-load-balancers | jq -r '.LoadBalancerDescriptions[] | select(.VPCId=="vpc-00de1af3d48f7c390")'
```

### "ACM Certificate is in use"

**Cause:** LoadBalancers still using the certificate

**Fix:**
```bash
# Find what's using the cert
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:324169293624:certificate/67900090-29db-4c9c-84d1-b4124d08efd7 \
  | jq -r '.Certificate.InUseBy[]'

# Delete those resources first
```

## Best Practice: Always Clean Before Destroy

Add this to your workflow:

```bash
#!/usr/bin/env bash
# destroy-env.sh

ENV=${1:-prod}
CLUSTER="vytalmed-${ENV}-eks"

echo "Cleaning up Kubernetes resources..."
./scripts/cleanup-before-destroy.sh "$CLUSTER"

echo "Waiting for AWS cleanup..."
sleep 30

echo "Running terraform destroy..."
terraform destroy -auto-approve

echo "Destroy complete!"
```

## Files Added for Cleanup

1. **cleanup-before-destroy.tf** - Terraform-managed cleanup with null_resource
2. **ssm-cleanup-on-destroy.tf** - SSM document for bastion-based cleanup
3. **scripts/cleanup-before-destroy.sh** - Manual cleanup script
4. **DESTROY_GUIDE.md** - This guide

## Modified Files

- **network.tf** - Added `depends_on = [time_sleep.wait_for_k8s_cleanup]` to VPC
- **ssl-dns.tf** - Added `depends_on = [time_sleep.wait_for_k8s_cleanup]` to ACM cert
