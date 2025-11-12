# ============================================
# ssm-grafana-dashboards.tf
# SSM Document to import Grafana dashboards
# ============================================

resource "aws_ssm_document" "grafana_dashboards" {
  name            = "${local.name_prefix}-grafana-dashboards"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Configure Grafana dashboards for EKS monitoring"
    parameters = {
      GrafanaWorkspaceId = {
        type        = "String"
        description = "Grafana Workspace ID"
      }
      Region = {
        type        = "String"
        description = "AWS Region"
        default     = data.aws_region.current.name
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
            "REGION='{{ Region }}'",
            "GRAFANA_ENDPOINT=\"https://$${GRAFANA_WORKSPACE_ID}.grafana-workspace.$${REGION}.amazonaws.com\"",
            "",
            "echo \"[Grafana] Configuring dashboards for workspace: $${GRAFANA_WORKSPACE_ID}\"",
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
            "# Function to import dashboard",
            "import_dashboard() {",
            "  local DASHBOARD_ID=$1",
            "  local DASHBOARD_NAME=$2",
            "  ",
            "  echo \"[Grafana] Importing dashboard: $${DASHBOARD_NAME} (ID: $${DASHBOARD_ID})\"",
            "  ",
            "  # Download dashboard JSON from Grafana.com",
            "  DASHBOARD_JSON=$(curl -s \"https://grafana.com/api/dashboards/$${DASHBOARD_ID}/revisions/latest/download\")",
            "  ",
            "  # Wrap in import format",
            "  IMPORT_PAYLOAD=$(jq -n \\",
            "    --argjson dashboard \"$DASHBOARD_JSON\" \\",
            "    '{",
            "      dashboard: $dashboard,",
            "      overwrite: true,",
            "      inputs: [{",
            "        name: \"DS_PROMETHEUS\",",
            "        type: \"datasource\",",
            "        pluginId: \"prometheus\",",
            "        value: \"Amazon Managed Prometheus\"",
            "      }]",
            "    }')",
            "  ",
            "  # Import to Grafana",
            "  IMPORT_RESPONSE=$(curl -s -X POST \\",
            "    \"$${GRAFANA_ENDPOINT}/api/dashboards/import\" \\",
            "    -H \"Authorization: Bearer $${API_KEY}\" \\",
            "    -H \"Content-Type: application/json\" \\",
            "    -d \"$IMPORT_PAYLOAD\")",
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

  tags = merge(
    local.tags,
    {
      Name      = "${local.name_prefix}-grafana-dashboards"
      Component = "Monitoring"
    }
  )
}

resource "aws_ssm_association" "grafana_dashboards" {
  count = local.monitoring_enabled ? 1 : 0
  name  = aws_ssm_document.grafana_dashboards.name

  targets {
    key    = "tag:Name"
    values = [local.bastion_name]
  }

  parameters = {
    GrafanaWorkspaceId = module.envs[local.primary_env].grafana_workspace_id
    Region             = data.aws_region.current.name
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.ssm_logs.id
    s3_key_prefix  = "grafana-dashboards/"
  }

  depends_on = [
    aws_ssm_association.prometheus_install,
    module.envs
  ]
}
