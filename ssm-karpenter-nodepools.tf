# ============================================
# SSM Document: Deploy Karpenter NodePools and EC2NodeClasses
# ============================================
locals {
  tags = {
    Tenant   = local.global_config.tenant_name
    Env      = local.primary_env
    Managed  = "Terraform"
    Project  = "EKS-Karpenter"
    Owner    = "Ops"
  }
}

locals {
  karpenter_config = try(local.environments[local.primary_env].karpenter, {})

  karpenter_resources_yaml = templatefile("${path.module}/karpenter-resources.yaml.tpl", {
    ami_family           = try(local.karpenter_config.ec2nodeclass.ami_family, "AL2023")
    instance_families    = try(local.karpenter_config.ec2nodeclass.instance_families, ["m5", "m6a", "c6a"])
    instance_sizes       = try(local.karpenter_config.ec2nodeclass.instance_sizes, ["large", "xlarge"])

    # 🔽 allow spot→on-demand fallback by default
    capacity_types       = try(local.karpenter_config.nodepool.capacity_types, ["spot", "on-demand"])

    cpu_limit            = try(local.karpenter_config.nodepool.limits.cpu, "1000")
    memory_limit         = try(local.karpenter_config.nodepool.limits.memory, "2000Gi")
    consolidation_policy = try(local.karpenter_config.nodepool.disruption.consolidation_policy, "WhenUnderutilized")
    consolidate_after    = try(local.karpenter_config.nodepool.disruption.consolidate_after, "5m")
    name_tag             = try(local.karpenter_config.ec2nodeclass.name_tag, "${lower(local.effective_tenant)}-${local.primary_env}-nodes-karpenter")
    env_name             = local.primary_env
  })
}


resource "aws_ssm_document" "karpenter_nodepools" {
  count        = local.karpenter_enabled ? 1 : 0
  name         = "${lower(local.effective_tenant)}-${local.primary_env}-karpenter-nodepools"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Apply Karpenter NodePool and EC2NodeClass"
    parameters = {
      Region = {
        type    = "String"
        default = local.effective_region
      }
      ClusterName = {
        type    = "String"
        default = module.envs[local.primary_env].eks_cluster_name
      }
      ResourcesYaml = {
        type    = "String"
        default = local.karpenter_resources_yaml
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
            "REGION='{{Region}}'",
            "CLUSTER_NAME='{{ClusterName}}'",

            # Kubeconfig env
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",

            "echo \"[Karpenter] Applying NodePool/EC2NodeClass to $CLUSTER_NAME\"",

            # Build kubeconfig for this cluster
            "aws eks update-kubeconfig --name \"$CLUSTER_NAME\" --region \"$REGION\" --kubeconfig \"$KUBECONFIG\"",

            # Sanity check: make sure we're talking to the real cluster, not localhost
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
            "for i in $(seq 1 40); do",
            "  refresh_discovery",
            "  if have_kind 'karpenter.k8s.aws' 'ec2nodeclasses' && have_kind 'karpenter.sh' 'nodepools'; then",
            "    echo \"[Karpenter] API discovery is ready (EC2NodeClass/NodePool visible)\"",
            "    break",
            "  fi",
            "  sleep 3",
            "  if [ \"$i\" -eq 40 ]; then echo \"[Karpenter] ERROR: API discovery never showed EC2NodeClass/NodePool\"; exit 1; fi",
            "done",

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

  tags = local.tags
}

resource "aws_ssm_association" "karpenter_nodepools_now" {
  count = local.karpenter_enabled ? 1 : 0
  name  = aws_ssm_document.karpenter_nodepools[0].name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = module.envs[local.primary_env].eks_cluster_name
  }

  depends_on = [
    module.envs,
    aws_ssm_association.install_karpenter_now,
  ]
}
