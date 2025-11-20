# SSM document that configures ArgoCD for per-environment repo and PAT

resource "aws_ssm_document" "argocd_wireup" {
  for_each = toset(local.enabled_environments)

  name          = "${lower(local.effective_tenant)}-${each.key}-argocd-wireup"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Register Argo CD repo via PAT, create App-of-Apps, and store admin password - per environment",
    parameters = {
      Environment = {
        type        = "String"
        description = "Environment name (prod, dev, etc.)"
      }
      Namespace = {
        type    = "String"
        default = "argocd"
      }
    },
    mainSteps = [
      {
        action = "aws:runShellScript",
        name   = "WireUpArgo",
        inputs = {
          runCommand = [
            "set -eo pipefail",
            "exec 2>&1",

            # Params
            "ENV='{{ Environment }}'",
            "NS='{{ Namespace }}'",
            "echo \"[Argo Wireup] Environment: $ENV\"",

            # Lookup environment-specific values from SSM
            "REGION=$(aws ssm get-parameter --name /terraform/shared/region --query 'Parameter.Value' --output text 2>/dev/null || echo 'us-east-1')",
            "CLUSTER=$(aws ssm get-parameter --name /terraform/envs/$ENV/cluster_name --query 'Parameter.Value' --output text --region $REGION)",
            "REPO_URL=$(aws ssm get-parameter --name /terraform/envs/$ENV/argocd/repo_url --query 'Parameter.Value' --output text --region $REGION)",
            "REPO_USER=$(aws ssm get-parameter --name /terraform/envs/$ENV/argocd/repo_username --query 'Parameter.Value' --output text --region $REGION)",
            "PAT_PARAM=$(aws ssm get-parameter --name /terraform/envs/$ENV/argocd/repo_pat_param --query 'Parameter.Value' --output text --region $REGION)",
            "APP_PATH=$(aws ssm get-parameter --name /terraform/envs/$ENV/argocd/app_path --query 'Parameter.Value' --output text --region $REGION)",
            "PROJECT=$(aws ssm get-parameter --name /terraform/envs/$ENV/argocd/project --query 'Parameter.Value' --output text --region $REGION)",

            "echo \"Configuration loaded for $ENV\"",
            "echo \"  Cluster: $CLUSTER\"",
            "echo \"  Repo: $REPO_URL\"",
            "echo \"[Argo Wireup] Region=$${REGION} Cluster=$${CLUSTER}\"",

            # Kubeconfig env
            "export HOME=/root",
            "mkdir -p /root/.kube",
            "export KUBECONFIG=/root/.kube/config",
            "export AWS_REGION=\"$REGION\" AWS_DEFAULT_REGION=\"$REGION\"",
            "set -u",

            # Sanity checks
            "aws sts get-caller-identity 1>/dev/null",
            "aws eks describe-cluster --name \"$CLUSTER\" --region \"$REGION\" 1>/dev/null",

            # Build kubeconfig
            "aws eks update-kubeconfig --region \"$REGION\" --name \"$CLUSTER\" --alias \"$CLUSTER\" --kubeconfig \"$KUBECONFIG\"",

            # Test if namespace exists
            "kubectl get ns \"$NS\" 2>/dev/null || kubectl create ns \"$NS\"",

            # --- fetch PAT from SSM ---
            "echo \"[Argo Wireup] Reading PAT from SSM: $${PAT_PARAM}\"",
            "PAT=$(aws ssm get-parameter --with-decryption --name \"$${PAT_PARAM}\" --query 'Parameter.Value' --output text)",

            # --- create repo secret ---
            "cat <<EOF >/tmp/argocd-repo-secret.yaml",
            "apiVersion: v1",
            "kind: Secret",
            "metadata:",
            "  name: argocd-repo-main",
            "  namespace: argocd",
            "  labels:",
            "    argocd.argoproj.io/secret-type: repository",
            "type: Opaque",
            "stringData:",
            "  url: \"$${REPO_URL}\"",
            "  username: \"$${REPO_USER}\"",
            "  password: \"$${PAT}\"",
            "EOF",
            "kubectl apply -f /tmp/argocd-repo-secret.yaml",

            # --- app-of-apps ---
            "cat <<EOF >/tmp/app-of-apps.yaml",
            "apiVersion: argoproj.io/v1alpha1",
            "kind: Application",
            "metadata:",
            "  name: app-of-apps",
            "  namespace: argocd",
            "spec:",
            "  project: \"$${PROJECT}\"",
            "  source:",
            "    repoURL: \"$${REPO_URL}\"",
            "    targetRevision: HEAD",
            "    path: \"$${APP_PATH}\"",
            "  destination:",
            "    server: https://kubernetes.default.svc",
            "    namespace: argocd",
            "  syncPolicy:",
            "    automated:",
            "      prune: true",
            "      selfHeal: true",
            "    syncOptions:",
            "      - CreateNamespace=true",
            "EOF",
            "kubectl apply -f /tmp/app-of-apps.yaml",

            # --- dump the initial admin password to SSM (handy for CI) ---
            "ADMIN_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d || true)",
            "if [ -n \"$${ADMIN_PW}\" ]; then",
            "  PARAM_NAME=\"/eks/$${CLUSTER}/argocd/admin_password\"",
            "  aws ssm put-parameter --name \"$${PARAM_NAME}\" --type SecureString --overwrite --value \"$${ADMIN_PW}\"",
            "  echo \"Stored Argo admin password in SSM: $${PARAM_NAME}\"",
            "else",
            "  echo \"Admin password not found (secret may have been deleted already). Skipping.\"",
            "fi"
          ]
        }
      }
    ]
  })
}

resource "aws_ssm_association" "argocd_wireup_now" {
  for_each = toset(local.enabled_environments)

  name = aws_ssm_document.argocd_wireup[each.key].name

  targets {
    key    = "tag:Environment"
    values = [each.key]
  }

  parameters = {
    Environment = each.key
    Namespace   = "argocd"
  }

  depends_on = [
    module.envs,
    aws_ssm_document.argocd_wireup,
    aws_ssm_association.install_argocd_now,
    aws_ssm_parameter.env_cluster_names,
    aws_ssm_parameter.env_argocd_repo_urls,
    aws_ssm_parameter.env_argocd_repo_usernames,
    aws_ssm_parameter.env_argocd_repo_pat_params,
    aws_ssm_parameter.env_argocd_app_paths,
    aws_ssm_parameter.env_argocd_projects,
  ]
}
