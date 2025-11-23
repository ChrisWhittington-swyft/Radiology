#!/bin/bash
set -e

REGION="${1:-us-east-1}"
ENV="${2:-dev}"

echo "=== Verifying AWS Resources for Monitoring ==="
echo "Region: $REGION"
echo "Environment: $ENV"
echo

echo "=== 1. RDS Instances ==="
echo "Looking for RDS with Env=$ENV tag..."
aws rds describe-db-instances --region $REGION \
  --query "DBInstances[?contains(TagList[].Key, 'Env')].{ID:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Tags:TagList}" \
  --output table

echo
echo "=== 2. RDS Clusters ==="
echo "Looking for Aurora clusters with Env=$ENV tag..."
aws rds describe-db-clusters --region $REGION \
  --query "DBClusters[?contains(TagList[].Key, 'Env')].{ID:DBClusterIdentifier,Engine:Engine,Status:Status,Tags:TagList}" \
  --output table

echo
echo "=== 3. ElastiCache Clusters ==="
echo "Looking for ElastiCache with Env=$ENV tag..."
aws elasticache describe-cache-clusters --region $REGION \
  --query "CacheClusters[*].{ID:CacheClusterId,Engine:Engine,Status:CacheClusterStatus,ReplicationGroup:ReplicationGroupId}" \
  --output table

echo
echo "=== 4. ElastiCache Replication Groups ==="
aws elasticache describe-replication-groups --region $REGION \
  --query "ReplicationGroups[*].{ID:ReplicationGroupId,Status:Status,NodeGroups:NodeGroups[].NodeGroupMembers[].CacheClusterId}" \
  --output table

echo
echo "=== 5. Kafka (MSK) Clusters ==="
echo "Looking for MSK clusters..."
aws kafka list-clusters --region $REGION \
  --query "ClusterInfoList[*].{Name:ClusterName,ARN:ClusterArn,State:State}" \
  --output table

echo
echo "=== 6. Detailed RDS Tags Check ==="
for db in $(aws rds describe-db-instances --region $REGION --query 'DBInstances[].DBInstanceIdentifier' --output text); do
  echo "DB Instance: $db"
  aws rds list-tags-for-resource --region $REGION \
    --resource-name "arn:aws:rds:$REGION:$(aws sts get-caller-identity --query Account --output text):db:$db" \
    --query 'TagList[?Key==`Env` || Key==`Name`]' --output table
  echo
done

echo
echo "=== 7. Detailed Aurora Cluster Tags Check ==="
for cluster in $(aws rds describe-db-clusters --region $REGION --query 'DBClusters[].DBClusterIdentifier' --output text); do
  echo "DB Cluster: $cluster"
  aws rds list-tags-for-resource --region $REGION \
    --resource-name "arn:aws:rds:$REGION:$(aws sts get-caller-identity --query Account --output text):cluster:$cluster" \
    --query 'TagList[?Key==`Env` || Key==`Name`]' --output table
  echo
done

echo "=== Done ==="
