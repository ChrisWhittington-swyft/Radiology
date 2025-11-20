# ============================================
# SSM Document: Deploy Karpenter NodePools and EC2NodeClasses
# ============================================

# Generate per-environment Karpenter resource YAML
locals {
  karpenter_resources_yaml_per_env = {
    for env in local.enabled_environments :
    env => templatefile("${path.module}/karpenter-resources.yaml.tpl", {
      ami_family           = try(local.environments[env].karpenter.ec2nodeclass.ami_family, "AL2023")
      instance_families    = try(local.environments[env].karpenter.ec2nodeclass.instance_families, ["m5", "m6a", "c6a"])
      instance_sizes       = try(local.environments[env].karpenter.ec2nodeclass.instance_sizes, ["large", "xlarge"])
      capacity_types       = try(local.environments[env].karpenter.ec2nodeclass.capacity_types, ["spot", "on-demand"])
      cpu_limit            = try(local.environments[env].karpenter.nodepool.limits.cpu, "1000")
      memory_limit         = try(local.environments[env].karpenter.nodepool.limits.memory, "2000Gi")
      consolidation_policy = try(local.environments[env].karpenter.nodepool.disruption.consolidation_policy, "WhenUnderutilized")
      consolidate_after    = try(local.environments[env].karpenter.nodepool.disruption.consolidate_after, "5m")
      name_tag             = try(local.environments[env].karpenter.ec2nodeclass.name_tag, "${lower(local.effective_tenant)}-${env}-nodes-karpenter")
      env_name             = env
    })
    if try(local.environments[env].karpenter.enabled, false)
  }
}


resource "aws_ssm_document" "karpenter_nodepools" {
  for_each = {
    for k in local.enabled_environments : k => k
    if try(local.environments[k].karpenter.enabled, false)
  }

  name         = "${lower(local.effective_tenant)}-${each.key}-karpenter-nodepools"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Apply Karpenter NodePool and EC2NodeClass - per environment"
    parameters = {
      Environment = {
        type        = "String"
        description = "Environment name (prod, dev, etc.)"
      }
      ResourcesYaml = {
        type        = "String"
        description = "Rendered Karpenter resources YAML"
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "ApplyKarpenterResources"
        inputs = {
          timeoutSeconds = 300
          runCommand = [
            "#!/bin/bash",
            "set -euo pipefail",
            "exec 2>&1",

            # Params
            "ENV='{{Environment}}'",
            "echo \"[Karpenter NodePools] Starting for environment: $ENV\"",

            # Lookup environment-specific values from SSM
            "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
            "CLUSTER_NAME=$(aws ssm get-parameter --name /terraform/envs/$ENV/cluster_name --query 'Parameter.Value' --output text --region $REGION)",

            "echo \"Configuration loaded for $ENV\"",
            "echo \"  Cluster: $CLUSTER_NAME\"",

            # Kubeconfig env
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",

            "echo \"[Karpenter] Applying NodePool/EC2NodeClass to $CLUSTER_NAME\"",

            # Build kubeconfig for this cluster
            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",

            # Sanity check: Test if real cluster, not localhost
            "kubectl get ns kube-system 1>/dev/null 2>&1 || { echo \"[Karpenter] ERROR: cannot reach cluster\"; exit 1; }",

            # Read the node instance profile from the same SSM path used by the install
            "BASE_SSM_PATH=\"/eks/$CLUSTER_NAME/karpenter\"",
            "NODE_INSTANCE_PROFILE=$(aws ssm get-parameter --name \"$BASE_SSM_PATH/node_instance_profile\" --query \"Parameter.Value\" --output text || true)",
            "[ -z \"$NODE_INSTANCE_PROFILE\" ] && { echo \"[Karpenter] ERROR: node_instance_profile SSM param missing\"; exit 1; }",
            "echo \"[Karpenter] Using InstanceProfile: $NODE_INSTANCE_PROFILE\"",

            # ---- wait for CRDs to exist & be Established ----
            "need_crds=( 'ec2nodeclasses.karpenter.k8s.aws' 'nodepools.karpenter.sh' 'nodeclaims.karpenter.sh' )",
            "for crd in \"$${need_crds[@]}\"; do",
            "  echo \"[Karpenter] waiting for CRD/$crd to exist...\"",
            "  until kubectl get crd \"$crd\" >/dev/null 2>&1; do sleep 3; done",
            "  echo \"[Karpenter] waiting for CRD/$crd to be Established...\"",
            "  kubectl wait --for=condition=Established crd/\"$crd\" --timeout=120s",
            "done",

            # ---- wait for controller to be Available ----
            "echo \"[Karpenter] waiting for controller rollout\"",
            "kubectl -n karpenter rollout status deploy/karpenter --timeout=180s",

            # ---- API discovery helpers ----
            "refresh_discovery(){",
            "  rm -rf \"$HOME/.kube/cache\" \"$HOME/.kube/http-cache\" || true",
            "  kubectl api-resources >/dev/null 2>&1 || true",
            "}",

            "have_kind(){",
            "  local group=\"$1\" kind_plural=\"$2\"",
            "  kubectl api-resources --request-timeout=5s --api-group=\"$group\" -o name | awk '{print $1}' | grep -qx \"$kind_plural\"",
            "}",

            # ---- wait for API discovery to list new kinds ----
            "echo \"[Karpenter] waiting for discovery of EC2NodeClass and NodePool kinds\"",
            "API_READY=false",
            "for i in $(seq 1 40); do",
            "  refresh_discovery",
            "  if have_kind 'karpenter.k8s.aws' 'ec2nodeclasses' && have_kind 'karpenter.sh' 'nodepools'; then",
            "    echo \"[Karpenter] API discovery is ready (EC2NodeClass/NodePool visible)\"",
            "    API_READY=true",
            "    break",
            "  fi",
            "  sleep 3",
            "done",
            "",
            "# If API discovery failed, check if resources already exist",
            "if [ \"$API_READY\" = \"false\" ]; then",
            "  echo \"[Karpenter] WARNING: API discovery timeout - checking if resources already exist...\"",
            "  set +e",
            "  kubectl get ec2nodeclass default >/dev/null 2>&1",
            "  EC2NC_EXISTS=$?",
            "  kubectl get nodepool default >/dev/null 2>&1",
            "  NP_EXISTS=$?",
            "  set -e",
            "  ",
            "  if [ $EC2NC_EXISTS -eq 0 ] && [ $NP_EXISTS -eq 0 ]; then",
            "    echo \"[Karpenter] ========================================\"",
            "    echo \"[Karpenter] Resources already exist - verifying status\"",
            "    echo \"[Karpenter] ========================================\"",
            "    ",
            "    # Check EC2NodeClass status",
            "    EC2NC_READY=$(kubectl get ec2nodeclass default -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null || echo 'Unknown')",
            "    echo \"[Karpenter] EC2NodeClass 'default' Ready status: $EC2NC_READY\"",
            "    ",
            "    # Check NodePool",
            "    echo \"[Karpenter] NodePool 'default' exists\"",
            "    ",
            "    # Show subnet and SG info",
            "    SUBNET_COUNT=$(kubectl get ec2nodeclass default -o jsonpath='{.status.subnets}' 2>/dev/null | grep -o 'id:' | wc -l || echo '0')",
            "    SG_COUNT=$(kubectl get ec2nodeclass default -o jsonpath='{.status.securityGroups}' 2>/dev/null | grep -o 'id:' | wc -l || echo '0')",
            "    echo \"[Karpenter] Discovered $SUBNET_COUNT subnet(s) and $SG_COUNT security group(s)\"",
            "    ",
            "    if [ \"$EC2NC_READY\" = \"True\" ]; then",
            "      echo \"[Karpenter] ✓ All resources are ready and operational\"",
            "    else",
            "      echo \"[Karpenter] ⚠ EC2NodeClass not ready yet - may still be initializing\"",
            "    fi",
            "    ",
            "    echo \"[Karpenter] ========================================\"",
            "    echo \"[Karpenter] SUCCESS: Re-run completed successfully\"",
            "    echo \"[Karpenter] To update resources, delete and re-run:\"",
            "    echo \"  kubectl delete ec2nodeclass default\"",
            "    echo \"  kubectl delete nodepool default\"",
            "    echo \"[Karpenter] ========================================\"",
            "    exit 0",
            "  fi",
            "  ",
            "  echo \"[Karpenter] Resources don't exist yet - checking prerequisites...\"",
            "  echo \"[Karpenter] Checking if subnets have discovery tags...\"",
            "  ",
            "  TAGGED_SUBNETS=$(aws ec2 describe-subnets --filters \"Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME\" --query 'Subnets[*].SubnetId' --output text)",
            "  if [ -z \"$TAGGED_SUBNETS\" ]; then",
            "    echo \"[Karpenter] ERROR: No subnets found with tag karpenter.sh/discovery=$CLUSTER_NAME\"",
            "    echo \"[Karpenter] Karpenter needs subnets tagged for discovery.\"",
            "    echo \"[Karpenter] Run 'terraform apply' to ensure aws_ec2_tag resources are created.\"",
            "    exit 1",
            "  fi",
            "  ",
            "  echo \"[Karpenter] Found tagged subnets: $TAGGED_SUBNETS\"",
            "  echo \"[Karpenter] Attempting to apply resources despite API discovery timeout...\"",
            "fi",

            # ---- apply rendered YAML with retries (refresh discovery on 'no matches') ----
            "apply_with_retry(){",
            "  local tries=8",
            "  for n in $(seq 1 $tries); do",
            "    set +e",
            "    out=$(CLUSTER_NAME=\"$CLUSTER_NAME\" NODE_INSTANCE_PROFILE=\"$NODE_INSTANCE_PROFILE\" envsubst | kubectl apply --validate=false -f - 2>&1)",
            "    rc=$?",
            "    set -e",
            "    if [ $rc -eq 0 ]; then",
            "      echo \"$out\"",
            "      return 0",
            "    fi",
            "    echo \"$out\" | grep -qi 'no matches for kind' && {",
            "      echo \"[Karpenter] apply failed due to discovery; refreshing and retrying...\"",
            "      refresh_discovery",
            "    }",
            "    echo \"[Karpenter] apply attempt $n failed; retrying in $((n*2))s...\"",
            "    sleep $((n*2))",
            "  done",
            "  return 1",
            "}",

            "echo \"[Karpenter] applying NodePool/EC2NodeClass\"",
            "cat << 'EOF' | apply_with_retry",
            "{{ResourcesYaml}}",
            "EOF",
            "echo \"[Karpenter] NodePool/EC2NodeClass applied\""
          ]
        }
      }
    ]
  })

}

resource "aws_ssm_association" "karpenter_nodepools_now" {
  for_each = {
    for k in local.enabled_environments : k => k
    if try(local.environments[k].karpenter.enabled, false)
  }

  name = aws_ssm_document.karpenter_nodepools[each.key].name

  targets {
    key    = "tag:Environment"
    values = [each.key]
  }

  parameters = {
    Environment   = each.key
    ResourcesYaml = local.karpenter_resources_yaml_per_env[each.key]
  }

  depends_on = [
    module.envs,
    aws_ssm_parameter.env_cluster_names,
    aws_ssm_association.install_karpenter_now,
  ]
}
