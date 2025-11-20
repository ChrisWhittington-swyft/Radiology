# Orchestrator SSM document that executes all setup steps in sequence
resource "aws_ssm_document" "bootstrap_orchestrator" {
  name          = "bootstrap-orchestrator"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Orchestrate all bootstrap operations in correct order - per environment",
    parameters = {
      Environment = {
        type        = "String"
        description = "Environment name (prod, dev, etc.)"
      }
    },
    mainSteps = [
      {
        action = "aws:runShellScript",
        name   = "RunBootstrapSequence",
        inputs = {
          timeoutSeconds = 3600  # 1 hour total timeout
          runCommand = [
            "set -eo pipefail",
            "exec 2>&1",

            "ENV='{{ Environment }}'",
            "INSTANCE_ID=$(ec2-metadata --instance-id | cut -d ' ' -f 2)",
            "echo \"[Orchestrator] Starting bootstrap sequence for environment: $ENV\"",
            "echo \"[Orchestrator] Instance: $INSTANCE_ID\"",

            # Lookup environment-specific values from SSM
            "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
            "CLUSTER=$(aws ssm get-parameter --name /terraform/envs/$ENV/cluster_name --query 'Parameter.Value' --output text --region $REGION)",

            "echo \"Configuration loaded for $ENV\"",
            "echo \"  Region: $REGION\"",
            "echo \"  Cluster: $CLUSTER\"",

            # Helper function to run SSM document and wait
            "run_ssm_doc() {",
            "  local doc_name=\"$1\"",
            "  local params=\"$2\"",
            "  echo \"[Orchestrator] === Running: $doc_name ===\"",
            "  ",
            "  cmd_id=$(aws ssm send-command \\",
            "    --document-name \"$doc_name\" \\",
            "    --instance-ids \"$INSTANCE_ID\" \\",
            "    --parameters \"$params\" \\",
            "    --region \"$REGION\" \\",
            "    --query 'Command.CommandId' \\",
            "    --output text)",
            "  ",
            "  echo \"[Orchestrator] Command ID: $cmd_id\"",
            "  ",
            "  # Wait for completion",
            "  for i in $(seq 1 180); do",
            "    status=$(aws ssm get-command-invocation \\",
            "      --command-id \"$cmd_id\" \\",
            "      --instance-id \"$INSTANCE_ID\" \\",
            "      --region \"$REGION\" \\",
            "      --query 'Status' \\",
            "      --output text 2>/dev/null || echo 'Pending')",
            "    ",
            "    case \"$status\" in",
            "      Success)",
            "        echo \"[Orchestrator] ✓ $doc_name completed successfully\"",
            "        return 0",
            "        ;;",
            "      Failed|Cancelled|TimedOut)",
            "        echo \"[Orchestrator] ✗ $doc_name failed with status: $status\"",
            "        aws ssm get-command-invocation \\",
            "          --command-id \"$cmd_id\" \\",
            "          --instance-id \"$INSTANCE_ID\" \\",
            "          --region \"$REGION\" || true",
            "        return 1",
            "        ;;",
            "      *)",
            "        echo \"[Orchestrator] Waiting for $doc_name... ($status) [$i/180]\"",
            "        sleep 10",
            "        ;;",
            "    esac",
            "  done",
            "  ",
            "  echo \"[Orchestrator] ✗ Timeout waiting for $doc_name\"",
            "  return 1",
            "}",

            # 1. Bootstrap ingress controller and load balancer (FIRST - creates the NLB)
            "run_ssm_doc 'bootstrap-ingress-and-app' 'Environment=$ENV,Namespace=ingress-nginx' || exit 1",

            # 2. Install ArgoCD
            "run_ssm_doc 'install-argocd' 'Environment=$ENV,Namespace=argocd' || exit 1",

            # 3. Create ArgoCD ingress
            "run_ssm_doc 'argocd-ingress' 'Environment=$ENV,Namespace=argocd' || exit 1",

            # 4. Create DockerHub secret
            "run_ssm_doc 'create-dockerhub-secret' 'Environment=$ENV,Namespace=default,SecretName=docker-hub-secret' || exit 1",

            # 5. Wire up ArgoCD repos
            "run_ssm_doc 'argocd-wireup' 'Environment=$ENV,Namespace=argocd' || exit 1",

            # 6. Create backend secrets
            "run_ssm_doc 'backend-create-secret' 'Environment=$ENV' || exit 1",

            # 7. Check if Karpenter is enabled for this environment
            "KARPENTER_ENABLED=$(aws ssm get-parameter --name /terraform/envs/$ENV/karpenter/enabled --query 'Parameter.Value' --output text --region $REGION 2>/dev/null || echo 'false')",
            "if [ \"$KARPENTER_ENABLED\" = \"true\" ]; then",
            "  echo '[Orchestrator] Karpenter enabled, installing...'",
            "  TENANT=$(aws ssm get-parameter --name /terraform/shared/tenant --query 'Parameter.Value' --output text --region $REGION 2>/dev/null || echo 'ria')",
            "  KARPENTER_INSTALL_DOC=\"${lower(local.effective_tenant)}-$ENV-install-karpenter\"",
            "  KARPENTER_NODEPOOL_DOC=\"${lower(local.effective_tenant)}-$ENV-karpenter-nodepools\"",
            "  run_ssm_doc \"$KARPENTER_INSTALL_DOC\" 'Environment=$ENV,Namespace=karpenter' || exit 1",
            "  run_ssm_doc \"$KARPENTER_NODEPOOL_DOC\" 'Environment=$ENV' || exit 1",
            "else",
            "  echo '[Orchestrator] Karpenter disabled for $ENV, skipping'",
            "fi",

            "echo \"[Orchestrator] === All bootstrap steps completed successfully ===\"",
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "bootstrap_orchestrator_now" {
  for_each = toset(local.enabled_environments)

  name = aws_ssm_document.bootstrap_orchestrator.name

  targets {
    key    = "tag:Environment"
    values = [each.key]
  }

  parameters = {
    Environment = each.key
  }

  depends_on = [
    module.envs,
    aws_ssm_document.install_argocd,
    aws_ssm_document.argocd_wireup,
    aws_ssm_document.create_dockerhub_secret,
    aws_ssm_document.bootstrap_ingress,
    aws_ssm_document.argocd_ingress,
    aws_ssm_document.backend_secret,
    aws_acm_certificate_validation.wildcard,
  ]
}
