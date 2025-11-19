
resource "aws_ssm_document" "backend_secret" {
  name          = "backend-create-secret"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Create/refresh backend secrets from Secrets Manager (Aurora) + SSM",
    parameters = {
      Region            = { type = "String", default = local.effective_region }
      ClusterName       = { type = "String", default = module.envs[local.primary_env].eks_cluster_name }
      SecretName        = { type = "String", default = local.backend_cfg.secret_name }
      SecretNamespace   = { type = "String", default = local.backend_cfg.secret_namespace }
      DbSecretArn       = { type = "String", default = module.envs[local.primary_env].db_secret_arn }
      DbWriterEndpoint  = { type = "String", default = module.envs[local.primary_env].db_writer_endpoint }
      KafkaServer       = { type = "String", default = try(module.envs[local.primary_env].kafka_bootstrap_servers, local.backend_cfg.kafka_server) }
      SmsSid            = { type = "String", default = local.backend_cfg.sms_account_sid_value }
      SmsTok            = { type = "String", default = local.backend_cfg.sms_auth_token_value }
      SmsPhone          = { type = "String", default = local.backend_cfg.sms_phone_number }
      AwsKeyParam       = { type = "String", default = local.backend_cfg.aws_access_key_id }
      AwsSecretParam    = { type = "String", default = local.backend_cfg.aws_secret_key }
      S3Bucket          = { type = "String", default = local.backend_cfg.s3_bucket }
      S3Prefix          = { type = "String", default = local.backend_cfg.s3_prefix }
      TestMode          = { type = "String", default = local.backend_cfg.test_mode }
      AiMockMode        = { type = "String", default = local.backend_cfg.ai_mock_mode }
      SpringAiEnabled   = { type = "String", default = local.backend_cfg.spring_ai_enabled }
      RedisAuthParam    = { type = "String", default = module.envs[local.primary_env].redis_auth_param_name }
      RedisUrlParam     = { type = "String", default = module.envs[local.primary_env].redis_url_param_name }
      EncryptionSecret  = { type = "String", default = module.envs[local.primary_env].encryption_secret }
      CognitoSecretArn  = { type = "String", default = "" }
      CognitoClientId   = { type = "String", default = "" }
      CognitoIssuerUrl  = { type = "String", default = "" }

    },
    mainSteps = [
      {
        action = "aws:runShellScript",
        name   = "CreateSecret",
        inputs = {
          runCommand = [
            "set -eo pipefail",
            "exec 2>&1",

            # Params
            "REGION='{{ Region }}'",
            "CLUSTER='{{ ClusterName }}'",
            "SECRET_NAME='{{ SecretName }}'",
            "SECRET_NAMESPACE='{{ SecretNamespace }}'",
            "DB_SECRET_ARN='{{ DbSecretArn }}'",
            "DB_WRITER_ENDPOINT='{{ DbWriterEndpoint }}'",
            "KAFKA='{{ KafkaServer }}'",
            "SMS_ACCOUNT_SID='{{ SmsSid }}'",
            "SMS_AUTH_TOKEN='{{ SmsTok }}'",
            "SMS_PHONE_NUMBER='{{ SmsPhone }}'",
            "AWS_KEY_PARAM='{{ AwsKeyParam }}'",
            "AWS_SEC_PARAM='{{ AwsSecretParam }}'",
            "S3_BUCKET='{{ S3Bucket }}'",
            "S3_PREFIX='{{ S3Prefix }}'",
            "TEST_MODE='{{ TestMode }}'",
            "AI_MOCK='{{ AiMockMode }}'",
            "SPRING_AI='{{ SpringAiEnabled }}'",
            "ENCRYPTION_SECRET='{{ EncryptionSecret }}'",
            "COGNITO_SECRET_ARN='{{ CognitoSecretArn }}'",
            "COGNITO_CLIENT_ID='{{ CognitoClientId }}'",
            "COGNITO_ISSUER_URL='{{ CognitoIssuerUrl }}'",

            # Kubeconfig
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",
            "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\"",

            # Get Aurora creds JSON from Secrets Manager (default RDS format)
            "DB_JSON=$(aws secretsmanager get-secret-value --secret-id \"$DB_SECRET_ARN\" --query SecretString --output text)",
            "PGHOST=\"$DB_WRITER_ENDPOINT\"",
            "PGUSER=$(echo \"$DB_JSON\" | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"username\",\"\"))')",
            "PGPASSWORD=$(echo \"$DB_JSON\" | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"password\",\"\"))')",
            "PGDATABASE=$(echo \"$DB_JSON\" | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"dbname\",\"worklist\"))')",

            "[ -z \"$PGHOST\" ] && PGHOST=\"$DB_WRITER_ENDPOINT\"",

            # Pull other secrets from SSM
            "AWS_ACCESS_KEY_ID=$(aws ssm get-parameter --name \"$AWS_KEY_PARAM\" --query 'Parameter.Value' --output text)",
            "AWS_SECRET_ACCESS_KEY=$(aws ssm get-parameter --with-decryption --name \"$AWS_SEC_PARAM\" --query 'Parameter.Value' --output text)",

            # --- debug + robust fallbacks ---
            "echo \"[BK] DbWriterEndpoint param: $${DB_WRITER_ENDPOINT}\"",
            "echo \"[BK] PGHOST from secret: '$${PGHOST}'\"",
            "[ -z \"$${PGHOST}\" ] && PGHOST=\"$${DB_WRITER_ENDPOINT}\"",
            "echo \"[BK] PGHOST after fallback: '$${PGHOST}'\"",

            # If the RDS secret lacked dbname/username, default to Terraform env values
            "[ -z \"$${PGDATABASE}\" ] && PGDATABASE=\"${local.environments[local.primary_env].db_name}\"",
            "[ -z \"$${PGUSER}\" ] && PGUSER=\"${local.environments[local.primary_env].db_username}\"",
            "echo \"[dbg] Using PGHOST=$${PGHOST} PGUSER=$${PGUSER} PGDATABASE=$${PGDATABASE}\"",

            # Read Redis values from SSM
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Reading Redis params from SSM...\"",
            "REDIS_PASS=$(aws ssm get-parameter --name '{{ RedisAuthParam }}' --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)",
            "REDIS_URL_RAW=$(aws ssm get-parameter --name '{{ RedisUrlParam }}'  --query 'Parameter.Value' --output text 2>/dev/null || true)",

            # Parse hostname and port from URL (handles rediss://, optional creds, optional /db)
            "URL=\"$${REDIS_URL_RAW}\"",
            "REDIS_HOSTNAME=\"\"",
            "REDIS_PORT=\"\"",
            "if [ -n \"$${URL}\" ]; then",
            "  TMP=\"$${URL}\"",
            "  TMP=\"$${TMP#*://}\"",        # strip scheme (rediss://)
            "  TMP=\"$${TMP#*@}\"",          # strip creds if present
            "  TMP=\"$${TMP%%/*}\"",         # drop /db if present
            "  if echo \"$${TMP}\" | grep -q ':'; then",
            "    REDIS_HOSTNAME=\"$${TMP%%:*}\"",
            "    REDIS_PORT=\"$${TMP#*:}\"",
            "  else",
            "    REDIS_HOSTNAME=\"$${TMP}\"",
            "  fi",
            "fi",
            "[ -z \"$${REDIS_PORT}\" ] && REDIS_PORT=\"6379\"",
            "REDIS_SSL=\"true\"",
            "echo \"[BK] Redis config: HOST=$${REDIS_HOSTNAME} PORT=$${REDIS_PORT} SSL=$${REDIS_SSL}\"",

            # Create/replace Secret
            "kubectl -n \"$${SECRET_NAMESPACE}\" create secret generic \"$${SECRET_NAME}\" \\",
            "  --from-literal=TEST_MODE=\"$${TEST_MODE}\" \\",
            "  --from-literal=AI_MOCK_MODE=\"$${AI_MOCK}\" \\",
            "  --from-literal=SPRING_AI_ENABLED=\"$${SPRING_AI}\" \\",
            "  --from-literal=PGHOST=\"$${PGHOST}\" \\",
            "  --from-literal=PGUSER=\"$${PGUSER}\" \\",
            "  --from-literal=PGPASSWORD=\"$${PGPASSWORD}\" \\",
            "  --from-literal=PGDATABASE=\"$${PGDATABASE}\" \\",
            "  --from-literal=KAFKA_SERVER=\"$${KAFKA}\" \\",
            "  --from-literal=SMS_ACCOUNT_SID=\"$${SMS_ACCOUNT_SID}\" \\",
            "  --from-literal=SMS_AUTH_TOKEN=\"$${SMS_AUTH_TOKEN}\" \\",
            "  --from-literal=SMS_PHONE_NUMBER=\"$${SMS_PHONE_NUMBER}\" \\",
            "  --from-literal=AWS_BUCKET_NAME=\"$${S3_BUCKET}\" \\",
            "  --from-literal=AWS_BUCKET_PREFIX=\"$${S3_PREFIX}\" \\",
            "  --from-literal=AWS_REGION=\"$${REGION}\" \\",
            "  --from-literal=AWS_ACCESS_KEY_ID=\"$${AWS_ACCESS_KEY_ID}\" \\",
            "  --from-literal=AWS_SECRET_ACCESS_KEY=\"$${AWS_SECRET_ACCESS_KEY}\" \\",
            "  --from-literal=REDIS_HOSTNAME=\"$${REDIS_HOSTNAME}\" \\",
            "  --from-literal=REDIS_PASSWORD=\"$${REDIS_PASS}\" \\",
            "  --from-literal=REDIS_PORT=\"$${REDIS_PORT}\" \\",
            "  --from-literal=REDIS_SSL=\"$${REDIS_SSL}\" \\",
            "  --from-literal=ENCRYPTION_SECRET=\"$${ENCRYPTION_SECRET}\" \\",
            "  --dry-run=client -o yaml | kubectl apply -f -",
            "echo \"Created/updated Secret $${SECRET_NAMESPACE}/$${SECRET_NAME}\"",
            "",
            "# Headlamp OIDC secret (Cognito)",
            "echo \"[Headlamp] Creating/updating headlamp-oidc secret...\"",
            "if [ -n \"$${COGNITO_SECRET_ARN}\" ] && [ -n \"$${COGNITO_CLIENT_ID}\" ] && [ -n \"$${COGNITO_ISSUER_URL}\" ]; then",
            "  COGNITO_CLIENT_SECRET=$(aws secretsmanager get-secret-value --secret-id \"$${COGNITO_SECRET_ARN}\" --query SecretString --output text)",
            "  kubectl get ns headlamp 2>/dev/null || kubectl create ns headlamp",
            "  kubectl -n headlamp create secret generic headlamp-oidc \\",
            "    --from-literal=clientSecret=\"$${COGNITO_CLIENT_SECRET}\" \\",
            "    --from-literal=clientId=\"$${COGNITO_CLIENT_ID}\" \\",
            "    --from-literal=issuerUrl=\"$${COGNITO_ISSUER_URL}\" \\",
            "    --dry-run=client -o yaml | kubectl apply -f -",
            "  echo '[Headlamp] Created/updated Secret headlamp/headlamp-oidc'",
            "else",
            "  echo '[Headlamp] Skipping headlamp-oidc secret (Cognito params not provided)'",
            "fi",
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "backend_secret_now" {
  for_each = module.envs

  name = aws_ssm_document.backend_secret.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-${each.key}-bastion"]
  }

  parameters = {
    Region           = local.effective_region
    ClusterName      = each.value.eks_cluster_name
    SecretName       = local.environments[each.key].backend.secret_name
    SecretNamespace  = local.environments[each.key].backend.secret_namespace
    DbSecretArn      = each.value.db_secret_arn
    DbWriterEndpoint = each.value.db_writer_endpoint
    KafkaServer      = try(each.value.kafka_bootstrap_servers, local.environments[each.key].backend.kafka_server)
    SmsSid           = local.environments[each.key].backend.sms_account_sid_value
    SmsTok           = local.environments[each.key].backend.sms_auth_token_value
    SmsPhone         = local.environments[each.key].backend.sms_phone_number
    AwsKeyParam      = local.environments[each.key].backend.aws_access_key_id
    AwsSecretParam   = local.environments[each.key].backend.aws_secret_key
    S3Bucket         = local.environments[each.key].backend.s3_bucket
    S3Prefix         = local.environments[each.key].backend.s3_prefix
    TestMode         = local.environments[each.key].backend.test_mode
    AiMockMode       = local.environments[each.key].backend.ai_mock_mode
    SpringAiEnabled  = local.environments[each.key].backend.spring_ai_enabled
    RedisAuthParam   = each.value.redis_auth_param_name
    RedisUrlParam    = each.value.redis_url_param_name
    EncryptionSecret = each.value.encryption_secret
    CognitoSecretArn = aws_secretsmanager_secret.headlamp_cognito.arn
    CognitoClientId  = aws_cognito_user_pool_client.headlamp.id
    CognitoIssuerUrl = "https://cognito-idp.${local.effective_region}.amazonaws.com/${aws_cognito_user_pool.headlamp.id}"
  }

  depends_on = [
    aws_ssm_parameter.backend_access_key_id,
    aws_ssm_parameter.backend_secret_access_key,
    aws_ssm_association.install_argocd_now,      # argo installed
    aws_ssm_association.argocd_ingress_now,      # ingress is up
    aws_secretsmanager_secret_version.headlamp_cognito,  # cognito secret ready
  ]
}
