# Orchestrator SSM document that executes all setup steps in sequence
resource "aws_ssm_document" "bootstrap_orchestrator" {
  name          = "bootstrap-orchestrator"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Orchestrate all bootstrap operations in correct order",
    parameters = {
      Region      = { type = "String", default = local.effective_region }
      ClusterName = { type = "String", default = module.envs[local.primary_env].eks_cluster_name }
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

            "REGION='{{ Region }}'",
            "CLUSTER='{{ ClusterName }}'",
            "INSTANCE_ID=$(ec2-metadata --instance-id | cut -d ' ' -f 2)",

            "echo \"[Orchestrator] Starting bootstrap sequence for $CLUSTER in $REGION\"",
            "echo \"[Orchestrator] Instance: $INSTANCE_ID\"",

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
            "run_ssm_doc 'bootstrap-ingress-and-app' 'Region=$REGION,ClusterName=$CLUSTER,AcmArn=${aws_acm_certificate.wildcard.arn},AppHost=${local.app_host},Namespace=ingress-nginx,IngressNlbName=${local.ingress_nlb_name}' || exit 1",

            # 2. Install ArgoCD
            "run_ssm_doc 'install-argocd' 'Region=$REGION,ClusterName=$CLUSTER,Namespace=argocd' || exit 1",

            # 3. Create ArgoCD ingress
            "run_ssm_doc 'argocd-ingress' 'Region=$REGION,ClusterName=$CLUSTER,ArgoHost=argocd.${local.base_domain},Namespace=argocd' || exit 1",

            # 4. Create DockerHub secret
            "run_ssm_doc 'create-dockerhub-secret' 'Region=$REGION,ClusterName=$CLUSTER,UserParam=${local.environments[local.primary_env].argocd.dockerhub_user_param},PassParam=${local.environments[local.primary_env].argocd.dockerhub_pass_param},Namespace=default,SecretName=docker-hub-secret' || exit 1",

            # 5. Wire up ArgoCD repos
            "run_ssm_doc 'argocd-wireup' 'Region=$REGION,ClusterName=$CLUSTER,RepoURL=${local.environments[local.primary_env].argocd.repo_url},RepoUsername=${local.environments[local.primary_env].argocd.repo_username},RepoPatParam=${local.environments[local.primary_env].argocd.repo_pat_param_name},AppPath=${local.environments[local.primary_env].argocd.app_of_apps_path},Project=${local.environments[local.primary_env].argocd.project},Namespace=argocd' || exit 1",

            # 6. Create backend secrets
            "run_ssm_doc 'backend-create-secret' 'Region=$REGION,ClusterName=$CLUSTER,SecretName=${local.environments[local.primary_env].backend.secret_name},SecretNamespace=${local.environments[local.primary_env].backend.secret_namespace},DbSecretArn=${module.envs[local.primary_env].db_secret_arn},DbWriterEndpoint=${module.envs[local.primary_env].db_writer_endpoint},KafkaServer=${try(module.envs[local.primary_env].kafka_bootstrap_servers, local.backend_cfg.kafka_server)},SmsSid=${local.backend_cfg.sms_account_sid_value},SmsTok=${local.backend_cfg.sms_auth_token_value},SmsPhone=${local.backend_cfg.sms_phone_number},AwsKeyParam=${local.backend_cfg.aws_access_key_id},AwsSecretParam=${local.backend_cfg.aws_secret_key},S3Bucket=${local.backend_cfg.s3_bucket},S3Prefix=${local.backend_cfg.s3_prefix},TestMode=${local.backend_cfg.test_mode},AiMockMode=${local.backend_cfg.ai_mock_mode},SpringAiEnabled=${local.backend_cfg.spring_ai_enabled},RedisAuthParam=${module.envs[local.primary_env].redis_auth_param_name},RedisUrlParam=${module.envs[local.primary_env].redis_url_param_name},EncryptionSecret=${module.envs[local.primary_env].encryption_secret}' || exit 1",

            # 7. Install Karpenter (if enabled)
            local.karpenter_enabled ? "run_ssm_doc '${aws_ssm_document.install_karpenter[0].name}' 'Region=$REGION,ClusterName=$CLUSTER,Namespace=karpenter,Version=${local.karpenter_version}' || exit 1" : "echo '[Orchestrator] Karpenter disabled, skipping'",

            # 8. Deploy Karpenter NodePools (if enabled)
            local.karpenter_enabled ? "run_ssm_doc '${aws_ssm_document.karpenter_nodepools[0].name}' 'Region=$REGION,ClusterName=$CLUSTER' || exit 1" : "echo '[Orchestrator] Karpenter disabled, skipping nodepools'",

            "echo \"[Orchestrator] === All bootstrap steps completed successfully ===\"",
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "bootstrap_orchestrator_now" {
  name = aws_ssm_document.bootstrap_orchestrator.name

  targets {
    key    = "tag:SSMTarget"
    values = ["bastion-linux"]
  }

  parameters = {
    Region      = local.effective_region
    ClusterName = module.envs[local.primary_env].eks_cluster_name
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
