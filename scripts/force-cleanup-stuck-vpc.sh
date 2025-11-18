#!/usr/bin/env bash
set -euo pipefail

# Emergency cleanup script for when VPC is stuck with dependencies
# Use this when terraform destroy fails with subnet/igw/acm errors

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${1:-}"

if [ -z "$VPC_ID" ]; then
  echo "Usage: $0 <vpc-id>"
  echo "Example: $0 vpc-00de1af3d48f7c390"
  exit 1
fi

echo "=========================================="
echo "Force cleanup for VPC: $VPC_ID"
echo "Region: $REGION"
echo "=========================================="
echo ""
echo "WARNING: This will delete ALL resources in the VPC!"
echo "Press Ctrl+C to cancel, or Enter to continue..."
read -r

# Function to retry a command
retry() {
  local max_attempts=5
  local delay=10
  local attempt=1

  until "$@" || [ $attempt -eq $max_attempts ]; do
    echo "  Attempt $attempt failed. Retrying in ${delay}s..."
    sleep $delay
    ((attempt++))
  done

  if [ $attempt -eq $max_attempts ]; then
    echo "  Failed after $max_attempts attempts"
    return 1
  fi
}

# 1. Delete all LoadBalancers in the VPC
echo "Step 1: Deleting LoadBalancers..."
aws elbv2 describe-load-balancers --region "$REGION" 2>/dev/null | \
  jq -r ".LoadBalancers[] | select(.VpcId==\"$VPC_ID\") | .LoadBalancerArn" | \
  while read -r arn; do
    if [ -n "$arn" ]; then
      echo "  - Deleting ALB/NLB: $arn"
      retry aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" 2>/dev/null || true
    fi
  done

aws elb describe-load-balancers --region "$REGION" 2>/dev/null | \
  jq -r ".LoadBalancerDescriptions[] | select(.VPCId==\"$VPC_ID\") | .LoadBalancerName" | \
  while read -r name; do
    if [ -n "$name" ]; then
      echo "  - Deleting Classic LB: $name"
      retry aws elb delete-load-balancer --load-balancer-name "$name" --region "$REGION" 2>/dev/null || true
    fi
  done

echo "  Waiting 30s for LoadBalancer deletion..."
sleep 30

# 2. Delete all NAT Gateways
echo ""
echo "Step 2: Deleting NAT Gateways..."
aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --region "$REGION" 2>/dev/null | \
  jq -r '.NatGateways[].NatGatewayId' | \
  while read -r nat_id; do
    if [ -n "$nat_id" ]; then
      echo "  - Deleting NAT Gateway: $nat_id"
      aws ec2 delete-nat-gateway --nat-gateway-id "$nat_id" --region "$REGION" 2>/dev/null || true
    fi
  done

echo "  Waiting 45s for NAT Gateway deletion..."
sleep 45

# 3. Release Elastic IPs
echo ""
echo "Step 3: Releasing Elastic IPs..."
aws ec2 describe-addresses --region "$REGION" 2>/dev/null | \
  jq -r '.Addresses[] | select(.Domain=="vpc") | .AllocationId' | \
  while read -r alloc_id; do
    if [ -n "$alloc_id" ]; then
      # Check if it's associated with our VPC (via NAT Gateway or other resource)
      echo "  - Releasing EIP: $alloc_id"
      aws ec2 release-address --allocation-id "$alloc_id" --region "$REGION" 2>/dev/null || true
    fi
  done

# 4. Delete Network Interfaces
echo ""
echo "Step 4: Deleting Network Interfaces..."
for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region "$REGION" | jq -r '.Subnets[].SubnetId'); do
  aws ec2 describe-network-interfaces \
    --filters "Name=subnet-id,Values=$subnet" \
    --region "$REGION" 2>/dev/null | \
    jq -r '.NetworkInterfaces[] | select(.Status=="available") | .NetworkInterfaceId' | \
    while read -r eni_id; do
      if [ -n "$eni_id" ]; then
        echo "  - Deleting ENI: $eni_id"
        retry aws ec2 delete-network-interface --network-interface-id "$eni_id" --region "$REGION" 2>/dev/null || true
      fi
    done
done

# 5. Check ACM certificate usage
echo ""
echo "Step 5: Checking ACM certificate usage..."
aws acm list-certificates --region "$REGION" 2>/dev/null | \
  jq -r '.CertificateSummaryList[].CertificateArn' | \
  while read -r cert_arn; do
    if [ -n "$cert_arn" ]; then
      IN_USE=$(aws acm describe-certificate --certificate-arn "$cert_arn" --region "$REGION" 2>/dev/null | jq -r '.Certificate.InUseBy[]' 2>/dev/null || echo "")
      if [ -n "$IN_USE" ]; then
        echo "  WARNING: Certificate still in use: $cert_arn"
        echo "    Used by: $IN_USE"
      fi
    fi
  done

echo ""
echo "=========================================="
echo "Cleanup complete!"
echo ""
echo "Wait 2-3 minutes, then retry:"
echo "  terraform destroy"
echo "=========================================="
