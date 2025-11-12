# ============================================
# ssm-grafana-dashboards.tf
# SSM Document to import Grafana dashboards
# ============================================

resource "aws_ssm_document" "grafana_dashboards" {
  name            = "${lower(local.effective_tenant)}-${local.primary_env}-grafana-dashboards"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Configure Grafana datasource and dashboards for EKS monitoring"
    parameters = {
      GrafanaWorkspaceId = {
        type        = "String"
        description = "Grafana Workspace ID"
      }
      AMPWorkspaceEndpoint = {
        type        = "String"
        description = "AMP Workspace Prometheus Endpoint"
      }
      Region = {
        type        = "String"
        description = "AWS Region"
        default     = local.effective_region
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "configureGrafanaDashboards"
        inputs = {
          runCommand = [
            "#!/bin/bash",
            "set -e",
            "",
            "GRAFANA_WORKSPACE_ID='{{ GrafanaWorkspaceId }}'",
            "AMP_ENDPOINT='{{ AMPWorkspaceEndpoint }}'",
            "REGION='{{ Region }}'",
            "GRAFANA_ENDPOINT=\"https://$${GRAFANA_WORKSPACE_ID}.grafana-workspace.$${REGION}.amazonaws.com\"",
            "",
            "echo \"[Grafana] Configuring Grafana workspace: $${GRAFANA_WORKSPACE_ID}\"",
            "echo \"[Grafana] AMP Endpoint: $${AMP_ENDPOINT}\"",
            "",
            "# Get Grafana API key",
            "echo \"[Grafana] Creating API key for automation\"",
            "API_KEY_RESPONSE=$(aws grafana create-workspace-api-key \\",
            "  --workspace-id \"$${GRAFANA_WORKSPACE_ID}\" \\",
            "  --key-name \"terraform-automation-$(date +%s)\" \\",
            "  --key-role ADMIN \\",
            "  --seconds-to-live 3600 \\",
            "  --region \"$${REGION}\" \\",
            "  --output json)",
            "",
            "API_KEY=$(echo $API_KEY_RESPONSE | jq -r '.key')",
            "",
            "if [ -z \"$API_KEY\" ] || [ \"$API_KEY\" = \"null\" ]; then",
            "  echo \"[ERROR] Failed to create Grafana API key\"",
            "  exit 1",
            "fi",
            "",
            "echo \"[Grafana] API key created successfully\"",
            "",
            "# Configure AMP datasource",
            "echo \"[Grafana] Configuring AMP datasource\"",
            "DATASOURCE_PAYLOAD=$(cat <<EOF",
            "{",
            "  \"name\": \"Amazon Managed Prometheus\",",
            "  \"type\": \"prometheus\",",
            "  \"url\": \"$${AMP_ENDPOINT}\",",
            "  \"access\": \"proxy\",",
            "  \"isDefault\": true,",
            "  \"jsonData\": {",
            "    \"httpMethod\": \"POST\",",
            "    \"sigV4Auth\": true,",
            "    \"sigV4AuthType\": \"default\",",
            "    \"sigV4Region\": \"$${REGION}\"",
            "  }",
            "}",
            "EOF",
            ")",
            "",
            "DATASOURCE_RESPONSE=$(curl -s -X POST \\",
            "  \"$${GRAFANA_ENDPOINT}/api/datasources\" \\",
            "  -H \"Authorization: Bearer $${API_KEY}\" \\",
            "  -H \"Content-Type: application/json\" \\",
            "  -d \"$DATASOURCE_PAYLOAD\")",
            "",
            "if echo \"$DATASOURCE_RESPONSE\" | jq -e '.datasource.uid' > /dev/null 2>&1; then",
            "  DATASOURCE_UID=$(echo \"$DATASOURCE_RESPONSE\" | jq -r '.datasource.uid')",
            "  echo \"[SUCCESS] Datasource configured with UID: $${DATASOURCE_UID}\"",
            "elif echo \"$DATASOURCE_RESPONSE\" | jq -e '.message' | grep -q 'already exists'; then",
            "  echo \"[INFO] Datasource already exists, updating...\"",
            "  # Get existing datasource UID",
            "  EXISTING_DS=$(curl -s -X GET \\",
            "    \"$${GRAFANA_ENDPOINT}/api/datasources/name/Amazon%20Managed%20Prometheus\" \\",
            "    -H \"Authorization: Bearer $${API_KEY}\")",
            "  DATASOURCE_UID=$(echo \"$EXISTING_DS\" | jq -r '.uid')",
            "  # Update it",
            "  curl -s -X PUT \\",
            "    \"$${GRAFANA_ENDPOINT}/api/datasources/uid/$${DATASOURCE_UID}\" \\",
            "    -H \"Authorization: Bearer $${API_KEY}\" \\",
            "    -H \"Content-Type: application/json\" \\",
            "    -d \"$DATASOURCE_PAYLOAD\" > /dev/null",
            "  echo \"[SUCCESS] Datasource updated\"",
            "else",
            "  echo \"[WARNING] Datasource configuration returned: $DATASOURCE_RESPONSE\"",
            "fi",
            "",
            "# Function to import dashboard",
            "import_dashboard() {",
            "  local DASHBOARD_ID=$1",
            "  local DASHBOARD_NAME=$2",
            "  ",
            "  echo \"[Grafana] Importing dashboard: $${DASHBOARD_NAME} (ID: $${DASHBOARD_ID})\"",
            "  ",
            "  # Download dashboard JSON from Grafana.com and wrap in import format",
            "  TEMP_FILE=$(mktemp)",
            "  curl -s \"https://grafana.com/api/dashboards/$${DASHBOARD_ID}/revisions/latest/download\" | jq '{",
            "    dashboard: .,",
            "    overwrite: true,",
            "    inputs: [{",
            "      name: \"DS_PROMETHEUS\",",
            "      type: \"datasource\",",
            "      pluginId: \"prometheus\",",
            "      value: \"Amazon Managed Prometheus\"",
            "    }]",
            "  }' > \"$${TEMP_FILE}\"",
            "  ",
            "  # Import to Grafana using file",
            "  IMPORT_RESPONSE=$(curl -s -X POST \\",
            "    \"$${GRAFANA_ENDPOINT}/api/dashboards/import\" \\",
            "    -H \"Authorization: Bearer $${API_KEY}\" \\",
            "    -H \"Content-Type: application/json\" \\",
            "    -d @\"$${TEMP_FILE}\")",
            "  ",
            "  rm -f \"$${TEMP_FILE}\""
            "  ",
            "  if echo \"$IMPORT_RESPONSE\" | jq -e '.uid' > /dev/null 2>&1; then",
            "    echo \"[SUCCESS] Dashboard $${DASHBOARD_NAME} imported successfully\"",
            "  else",
            "    echo \"[WARNING] Failed to import $${DASHBOARD_NAME}: $IMPORT_RESPONSE\"",
            "  fi",
            "}",
            "",
            "# Import essential Kubernetes dashboards",
            "echo \"[Grafana] Starting dashboard imports\"",
            "",
            "# Kubernetes Cluster Monitoring",
            "import_dashboard \"7249\" \"Kubernetes Cluster Monitoring\"",
            "",
            "# Kubernetes Pod Monitoring",
            "import_dashboard \"6417\" \"Kubernetes Pod Monitoring\"",
            "",
            "# Node Exporter Full",
            "import_dashboard \"1860\" \"Node Exporter Full\"",
            "",
            "# Kubernetes API Server",
            "import_dashboard \"12006\" \"Kubernetes API Server\"",
            "",
            "# Kubernetes System API Server",
            "import_dashboard \"15761\" \"Kubernetes System API Server\"",
            "",
            "# Kubernetes Deployment Statefulset Daemonset metrics",
            "import_dashboard \"8588\" \"Kubernetes Deployment Statefulset Daemonset\"",
            "",
            "echo \"[Grafana] Dashboard import complete\"",
            "",
            "# Create folder for custom dashboards",
            "echo \"[Grafana] Creating custom dashboard folder\"",
            "FOLDER_RESPONSE=$(curl -s -X POST \\",
            "  \"$${GRAFANA_ENDPOINT}/api/folders\" \\",
            "  -H \"Authorization: Bearer $${API_KEY}\" \\",
            "  -H \"Content-Type: application/json\" \\",
            "  -d '{\"title\": \"EKS Monitoring\", \"uid\": \"eks-monitoring\"}')",
            "",
            "echo \"[Grafana] Configuration complete!\"",
            "echo \"[Grafana] Access URL: $${GRAFANA_ENDPOINT}\"",
          ]
        }
      }
    ]
  })

  tags = {
    Tenant   = local.effective_tenant
    Env      = local.primary_env
    Name     = "${lower(local.effective_tenant)}-${local.primary_env}-grafana-dashboards"
    Component = "Monitoring"
  }
}

resource "aws_ssm_association" "grafana_dashboards" {
  count = local.karpenter_enabled ? 1 : 0
  name  = aws_ssm_document.grafana_dashboards.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-bastion"]
  }

  parameters = {
    GrafanaWorkspaceId   = module.envs[local.primary_env].grafana_workspace_id
    AMPWorkspaceEndpoint = module.envs[local.primary_env].amp_workspace_endpoint
    Region               = local.effective_region
  }

  depends_on = [
    module.envs
  ]
}
