# Multi-Environment Architecture Refactor

## Summary

This refactor transforms the infrastructure from a pseudo-multi-env setup (where only the "primary" environment was actually configured) to a true multi-environment architecture where each environment gets its own complete stack.

## Key Changes

### 1. Bastion Host Per Environment

**Before:**
- Single bastion tagged as `${tenant}-${region}-bastion`
- All SSM associations targeted this one bastion
- Collision if multiple environments enabled

**After:**
- Per-environment bastions tagged as `${tenant}-${region}-${env}-bastion`
- Each environment has isolated management host
- File: `modules/envs/bastion.tf:19`

### 2. SSM Associations Now Per-Environment

**Before:**
```hcl
resource "aws_ssm_association" "install_argocd_now" {
  name = aws_ssm_document.install_argocd.name
  targets {
    values = ["${tenant}-${region}-bastion"]  # Single bastion
  }
  parameters = {
    ClusterName = module.envs[local.primary_env].eks_cluster_name  # Only primary!
  }
}
```

**After:**
```hcl
resource "aws_ssm_association" "install_argocd_now" {
  for_each = module.envs  # Loop over ALL environments

  name = aws_ssm_document.install_argocd.name
  targets {
    values = ["${tenant}-${region}-${each.key}-bastion"]  # Per-env bastion
  }
  parameters = {
    ClusterName = each.value.eks_cluster_name  # Per-env cluster
  }
}
```

**Files Updated:**
- `ssm-argocd-install.tf` - ArgoCD installation
- `ssm-argocd-repos.tf` - ArgoCD repo configuration
- `ssm-argocd-ui.tf` - ArgoCD ingress
- `ssm-backend-secrets.tf` - Backend secrets
- `ssm-dockerhub.tf` - DockerHub secrets
- `ssm-ingress.tf` - NGINX ingress controller
- `ssm-karpenter-install.tf` - Karpenter installation
- `ssm-karpenter-nodepools.tf` - Karpenter node pools
- `ssm-prometheus-install.tf` - Prometheus stack
- `ssm-prometheus-alerts.tf` - Prometheus alerting rules
- `ssm-alertmanager-sns.tf` - Alertmanager SNS forwarder
- `ssm-yace-install.tf` - YACE CloudWatch exporter
- `ssm-grafana-dashboards.tf` - Grafana dashboards
- `ssm-grafana-kafka-dashboard.tf` - Kafka dashboard

### 3. DNS Records Per Environment

**Before:**
- Single DNS record: `prod.vytalmed.app` → NLB of primary env
- Hard-coded to primary environment

**After:**
- Per-environment DNS records: `prod.vytalmed.app`, `dev.vytalmed.app`, etc.
- Each points to its own environment's NLB
- File: `ssl-dns.tf:80-92`

### 4. Network Tags Support Multiple Environments

**Before:**
```hcl
tags = {
  "karpenter.sh/discovery" = "${tenant}-${primary_env}-eks"
}
```

**After:**
```hcl
tags = merge({...},
  { for env in local.enabled_environments :
    "karpenter.sh/discovery/${tenant}-${env}-eks" => "true"
  })
```

Each EKS cluster can now discover the shared subnets via its own discovery tag.
File: `network.tf:73-101`

### 5. Monitoring Outputs Now Per-Environment

**Before:**
```hcl
output "amp_workspace_id" {
  value = module.envs[local.primary_env].amp_workspace_id
}
```

**After:**
```hcl
output "amp_workspace_ids" {
  value = { for k, v in module.envs : k => v.amp_workspace_id }
}
```

File: `monitoring-outputs.tf`

### 6. Backend Configuration Per Environment

Backend secrets (SMS, S3, AI settings) are now pulled from `local.environments[each.key].backend` instead of always using `primary_env`.

File: `ssm-backend-secrets.tf:182-191`

## What Stayed the Same

### Truly Global Resources

These resources remain at the root level and are NOT duplicated per environment:

1. **VPC and Networking** (`network.tf`)
   - Single VPC shared by all environments
   - Subnets tagged to be discoverable by all clusters

2. **Wildcard SSL Certificate** (`ssl-dns.tf`)
   - Single wildcard cert `*.vytalmed.app`
   - Shared by all environments

3. **Cognito User Pool** (`cognito-headlamp.tf`)
   - Single Headlamp authentication pool
   - Named with primary_env but shared (acceptable)

4. **IAM Roles for Backend** (`iam-backend.tf`)
   - S3, Textract, Bedrock IAM policies
   - Shared backend access (named with primary_env)

5. **Bootstrap IAM Parameters**
   - `/bootstrap/github_pat_ria`
   - `/bootstrap/backend/aws_access_key_id`
   - `/bootstrap/backend/aws_secret_access_key`

### SSM Document Names

SSM document names still reference `primary_env` for uniqueness:
- `${tenant}-${primary_env}-install-karpenter`
- `${tenant}-${primary_env}-install-prometheus`

This is acceptable since document names are global within an account, and the documents themselves are reusable. The associations (which run the documents) are now per-environment.

## How to Enable Multiple Environments

### Example: Add Dev Environment

Edit `instances.tf`:

```hcl
locals {
  enabled_environments = ["prod", "dev"]  # Add "dev"

  environments = {
    prod = {
      # existing prod config
    }

    dev = {
      cluster_version = "1.34"
      instance_types  = ["m5.large"]
      min_nodes       = 1
      max_nodes       = 5
      desired_nodes   = 2

      db_engine_version = "15"
      db_name           = "worklist"
      db_username       = "worklist"
      min_acus          = 2
      max_acus          = 8

      app_subdomain = "dev"

      argocd = {
        repo_url            = "https://github.com/BeNYMBL/Vytalmed-dev.git"
        repo_username       = "oauth2"
        repo_pat_param_name = "/bootstrap/github_pat_ria"
        app_of_apps_path    = "clusters/dev"
        project             = "default"
      }

      backend = {
        # dev-specific backend config
      }

      monitoring = { enabled = true }
      kafka      = { enabled = true }
      karpenter  = { enabled = true }
    }
  }
}
```

When you apply this:
- A new bastion `vytalmed-us-east-1-dev-bastion` will be created
- A new EKS cluster `vytalmed-dev-eks` will be created
- All SSM associations will run on the dev bastion
- DNS record `dev.vytalmed.app` will point to dev's NLB
- Separate Aurora, Redis, Kafka, and monitoring stack for dev

## Remaining Single-Environment Constraints

### Primary Environment Usage

`local.primary_env` is still used in a few places:

1. **ArgoCD DNS** (`ssl-dns.tf:67-77`)
   - `argocd.vytalmed.app` still points to primary env's NLB
   - Consider: `argocd-prod.vytalmed.app`, `argocd-dev.vytalmed.app`

2. **Default SSM Parameters** in document definitions
   - Document parameter defaults reference primary_env
   - Not a blocker since associations override these

3. **Global Flags** (`main.tf:137-145`)
   - `local.karpenter_enabled` based on primary_env
   - `local.monitoring_enabled` based on primary_env
   - Used only for conditional SSM document creation (count-based)
   - Associations properly loop over envs

## Testing Checklist

- [ ] Add a second environment to `instances.tf`
- [ ] Run `terraform plan` - verify no errors
- [ ] Verify bastion resources created per-env
- [ ] Verify SSM associations target correct bastions
- [ ] Check DNS records point to correct NLBs
- [ ] Verify Karpenter discovery tags on subnets
- [ ] Test SSM document execution on each bastion
- [ ] Verify per-env outputs

## Migration Notes

If you currently have infrastructure deployed with the old single-bastion setup:

1. **Bastion will be recreated** - Name tag changes from `${tenant}-${region}-bastion` to `${tenant}-${region}-${env}-bastion`
2. **SSM associations will update** - Target tag changes
3. **DNS records will update** - `subdomain-prod` becomes per-env `app_subdomain`
4. **No data loss** - EKS clusters, databases, etc. are unchanged

## Summary

The infrastructure now supports true multi-environment deployments where:
- Each environment is independently configured
- Each environment has its own bastion, EKS cluster, database, and services
- Shared resources (VPC, SSL cert) remain global
- SSM orchestration targets the correct environment automatically
