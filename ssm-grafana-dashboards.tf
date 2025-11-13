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
            "# Function to import dashboard with automatic datasource mapping",
            "import_dashboard() {",
            "  local DASHBOARD_ID=$1",
            "  local DASHBOARD_NAME=$2",
            "  ",
            "  echo \"[Grafana] Importing dashboard: $${DASHBOARD_NAME} (ID: $${DASHBOARD_ID})\"",
            "  ",
            "  # Download dashboard JSON",
            "  TEMP_DASHBOARD=$(mktemp)",
            "  TEMP_IMPORT=$(mktemp)",
            "  ",
            "  curl -s \"https://grafana.com/api/dashboards/$${DASHBOARD_ID}/revisions/latest/download\" > \"$${TEMP_DASHBOARD}\"",
            "  ",
            "  # Extract all datasource input variables and map them all to our Prometheus datasource",
            "  DS_INPUTS=$(jq -r '[.__inputs[]? | select(.type == \"datasource\" and .pluginId == \"prometheus\") | {name: .name, type: \"datasource\", pluginId: \"prometheus\", value: \"Amazon Managed Prometheus\"}]' < \"$${TEMP_DASHBOARD}\")",
            "  ",
            "  # If no inputs found, create default DS_PROMETHEUS mapping",
            "  if [ \"$${DS_INPUTS}\" = \"[]\" ] || [ -z \"$${DS_INPUTS}\" ]; then",
            "    DS_INPUTS='[{\"name\":\"DS_PROMETHEUS\",\"type\":\"datasource\",\"pluginId\":\"prometheus\",\"value\":\"Amazon Managed Prometheus\"}]'",
            "  fi",
            "  ",
            "  # Create import payload with folder assignment",
            "  jq -n \\",
            "    --slurpfile dashboard \"$${TEMP_DASHBOARD}\" \\",
            "    --argjson inputs \"$${DS_INPUTS}\" \\",
            "    --argjson folderId \"$${FOLDER_ID:-0}\" \\",
            "    '{dashboard: $dashboard[0], overwrite: true, inputs: $inputs, folderId: $folderId}' > \"$${TEMP_IMPORT}\"",
            "  ",
            "  # Import to Grafana",
            "  IMPORT_RESPONSE=$(curl -s -X POST \\",
            "    \"$${GRAFANA_ENDPOINT}/api/dashboards/import\" \\",
            "    -H \"Authorization: Bearer $${API_KEY}\" \\",
            "    -H \"Content-Type: application/json\" \\",
            "    -d @\"$${TEMP_IMPORT}\")",
            "  ",
            "  rm -f \"$${TEMP_DASHBOARD}\" \"$${TEMP_IMPORT}\"",
            "  ",
            "  if echo \"$IMPORT_RESPONSE\" | jq -e '.uid' > /dev/null 2>&1; then",
            "    echo \"[SUCCESS] Dashboard $${DASHBOARD_NAME} imported successfully\"",
            "  else",
            "    echo \"[WARNING] Failed to import $${DASHBOARD_NAME}: $IMPORT_RESPONSE\"",
            "  fi",
            "}",
            "",
            "# Create folder for dashboards first",
            "echo \"[Grafana] Creating EKS Monitoring folder\"",
            "FOLDER_RESPONSE=$(curl -s -X POST \\",
            "  \"$${GRAFANA_ENDPOINT}/api/folders\" \\",
            "  -H \"Authorization: Bearer $${API_KEY}\" \\",
            "  -H \"Content-Type: application/json\" \\",
            "  -d '{\"title\": \"EKS Monitoring\", \"uid\": \"eks-monitoring\"}')",
            "",
            "# Get folder ID (create returns id, or get existing if already exists)",
            "if echo \"$FOLDER_RESPONSE\" | jq -e '.id' > /dev/null 2>&1; then",
            "  FOLDER_ID=$(echo \"$FOLDER_RESPONSE\" | jq -r '.id')",
            "  echo \"[INFO] Folder created with ID: $${FOLDER_ID}\"",
            "else",
            "  # Folder might already exist, get it",
            "  FOLDER_RESPONSE=$(curl -s -X GET \\",
            "    \"$${GRAFANA_ENDPOINT}/api/folders/eks-monitoring\" \\",
            "    -H \"Authorization: Bearer $${API_KEY}\")",
            "  FOLDER_ID=$(echo \"$FOLDER_RESPONSE\" | jq -r '.id')",
            "  echo \"[INFO] Using existing folder ID: $${FOLDER_ID}\"",
            "fi",
            "",
            "# Import modern Kubernetes dashboards (React-based, actively maintained)",
            "echo \"[Grafana] Starting dashboard imports to EKS Monitoring folder\"",
            "",
            "# Modern Kubernetes Overview - comprehensive cluster health and performance",
            "import_dashboard \"17119\" \"Kubernetes Cluster Prometheus\"",
            "",
            "# Kubernetes Views - Modern kubernetes-mixin suite (Google SRE best practices)",
            "import_dashboard \"15760\" \"Kubernetes Global View\"",
            "import_dashboard \"15761\" \"Kubernetes Namespaces View\"",
            "import_dashboard \"15762\" \"Kubernetes Nodes View\"",
            "import_dashboard \"15763\" \"Kubernetes Pods View\"",
            "",
            "# Control Plane Health",
            "import_dashboard \"12006\" \"Kubernetes API Server\"",
            "",
            "# Karpenter-specific metrics for autoscaling insights",
            "import_dashboard \"14981\" \"Karpenter Capacity\"",
            "",
            "# Modern Node metrics (replaces old Angular-based dashboard)",
            "import_dashboard \"13978\" \"Node Exporter Quickstart\"",
            "",
            "echo \"[Grafana] Dashboard import complete\"",
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
