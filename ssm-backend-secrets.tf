
resource "aws_ssm_document" "backend_secret" {
  for_each = toset(local.enabled_environments)

  name          = "${lower(local.effective_tenant)}-${each.key}-backend-create-secret"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Create/refresh backend-secrets from Secrets Manager (Aurora) + SSM - per environment",
    parameters = {
      Environment = {
        type        = "String"
        description = "Environment name (prod, dev, etc.)"
      }
      DbSecretArn = {
        type        = "String"
        description = "ARN of the Aurora master secret"
        default     = module.envs[each.key].db_secret_arn
      }
      DbWriterEndpoint = {
        type        = "String"
        description = "Aurora writer endpoint"
        default     = module.envs[each.key].db_writer_endpoint
      }
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
            "ENV='{{ Environment }}'",
            "DB_SECRET_ARN='{{ DbSecretArn }}'",
            "DB_WRITER_ENDPOINT='{{ DbWriterEndpoint }}'",
            "echo \"[Backend Secrets] Starting for environment: $ENV\"",

            # Lookup environment-specific values from SSM
            "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
            "CLUSTER=$(aws ssm get-parameter --name /terraform/envs/$ENV/cluster_name --query 'Parameter.Value' --output text --region $REGION)",
            "SECRET_NAME=$(aws ssm get-parameter --name /terraform/envs/$ENV/backend/secret_name --query 'Parameter.Value' --output text --region $REGION)",
            "SECRET_NAMESPACE=$(aws ssm get-parameter --name /terraform/envs/$ENV/backend/secret_namespace --query 'Parameter.Value' --output text --region $REGION)",
            "AWS_KEY_PARAM=$(aws ssm get-parameter --name /terraform/envs/$ENV/backend/aws_access_key_param --query 'Parameter.Value' --output text --region $REGION)",
            "AWS_SEC_PARAM=$(aws ssm get-parameter --name /terraform/envs/$ENV/backend/aws_secret_key_param --query 'Parameter.Value' --output text --region $REGION)",
            "S3_BUCKET=$(aws ssm get-parameter --name /terraform/envs/$ENV/backend/s3_bucket --query 'Parameter.Value' --output text --region $REGION)",
            "S3_PREFIX=$(aws ssm get-parameter --name /terraform/envs/$ENV/backend/s3_prefix --query 'Parameter.Value' --output text --region $REGION)",
            "TEST_MODE=$(aws ssm get-parameter --name /terraform/envs/$ENV/backend/test_mode --query 'Parameter.Value' --output text --region $REGION)",
            "AI_MOCK=$(aws ssm get-parameter --name /terraform/envs/$ENV/backend/ai_mock_mode --query 'Parameter.Value' --output text --region $REGION)",
            "SPRING_AI=$(aws ssm get-parameter --name /terraform/envs/$ENV/backend/spring_ai_enabled --query 'Parameter.Value' --output text --region $REGION)",

            # Get Redis and Kafka metadata from module outputs stored in SSM
            "KAFKA=$(aws ssm get-parameter --name /eks/$CLUSTER/kafka/bootstrap_servers --query 'Parameter.Value' --output text --region $REGION 2>/dev/null || aws ssm get-parameter --name /terraform/envs/$ENV/backend/kafka_server --query 'Parameter.Value' --output text --region $REGION)",
            "REDIS_AUTH_PARAM=$(aws ssm get-parameter --name /eks/$CLUSTER/redis/auth_param --query 'Parameter.Value' --output text --region $REGION 2>/dev/null || true)",
            "REDIS_URL_PARAM=$(aws ssm get-parameter --name /eks/$CLUSTER/redis/url_param --query 'Parameter.Value' --output text --region $REGION 2>/dev/null || true)",
            "ENCRYPTION_SECRET=$(aws ssm get-parameter --name /eks/$CLUSTER/encryption_secret --query 'Parameter.Value' --output text --region $REGION 2>/dev/null || true)",
            "DB_NAME=$(aws ssm get-parameter --name /eks/$CLUSTER/db_name --query 'Parameter.Value' --output text --region $REGION 2>/dev/null || echo 'worklist')",
            "DB_USER=$(aws ssm get-parameter --name /eks/$CLUSTER/db_username --query 'Parameter.Value' --output text --region $REGION 2>/dev/null || echo 'worklist')",

            "echo \"Configuration loaded for $ENV\"",
            "echo \"  Cluster: $CLUSTER\"",
            "echo \"  Secret: $SECRET_NAMESPACE/$SECRET_NAME\"",
            "echo \"  DB: $DB_WRITER_ENDPOINT\"",

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

            # If the RDS secret lacked dbname/username, use defaults from SSM
            "[ -z \"$${PGDATABASE}\" ] && PGDATABASE=\"$${DB_NAME}\"",
            "[ -z \"$${PGUSER}\" ] && PGUSER=\"$${DB_USER}\"",
            "echo \"[dbg] Using PGHOST=$${PGHOST} PGUSER=$${PGUSER} PGDATABASE=$${PGDATABASE}\"",

            # Read Redis values from SSM
            "echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Reading Redis params from SSM...\"",
            "REDIS_PASS=$(aws ssm get-parameter --name \"$REDIS_AUTH_PARAM\" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)",
            "REDIS_URL_RAW=$(aws ssm get-parameter --name \"$REDIS_URL_PARAM\"  --query 'Parameter.Value' --output text 2>/dev/null || true)",

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
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "backend_secret_now" {
  for_each = toset(local.enabled_environments)

  name = aws_ssm_document.backend_secret[each.key].name

  targets {
    key    = "tag:Environment"
    values = [each.key]
  }

  parameters = {
    Environment      = each.key
    DbSecretArn      = module.envs[each.key].db_secret_arn
    DbWriterEndpoint = module.envs[each.key].db_writer_endpoint
  }

  depends_on = [
    module.envs,
    aws_ssm_parameter.backend_access_key_id,
    aws_ssm_parameter.backend_secret_access_key,
    aws_ssm_parameter.env_cluster_names,
    aws_ssm_parameter.env_backend_secret_names,
    aws_ssm_parameter.env_backend_secret_namespaces,
    aws_ssm_parameter.env_backend_aws_key_params,
    aws_ssm_parameter.env_backend_aws_secret_params,
    aws_ssm_parameter.env_backend_s3_buckets,
    aws_ssm_parameter.env_backend_s3_prefixes,
    aws_ssm_parameter.env_backend_test_modes,
    aws_ssm_parameter.env_backend_ai_mock_modes,
    aws_ssm_parameter.env_backend_spring_ai_enabled,
    aws_ssm_parameter.env_encryption_secrets,
    aws_ssm_parameter.env_redis_auth_params,
    aws_ssm_parameter.env_redis_url_params,
    aws_ssm_association.install_argocd_now,
    aws_ssm_association.argocd_ingress_now,
  ]
}
