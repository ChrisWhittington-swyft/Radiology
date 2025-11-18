# SSM document that configures ArgoCD for the locals-env repo and PAT

resource "aws_ssm_document" "argocd_wireup" {
  name          = "argocd-wireup"
  document_type = "Command"

  content = jsonencode({
    schemaVersion = "2.2",
    description   = "Register Argo CD repo via PAT, create App-of-Apps, and store admin password",
    parameters = {
      Region          = { type = "String", default = local.effective_region }
      ClusterName     = { type = "String", default = module.envs[local.primary_env].eks_cluster_name }
      RepoURL         = { type = "String", default = local.environments[local.primary_env].argocd.repo_url }
      RepoUsername    = { type = "String", default = local.environments[local.primary_env].argocd.repo_username }
      RepoPatParam    = { type = "String", default = local.environments[local.primary_env].argocd.repo_pat_param_name }
      AppPath         = { type = "String", default = local.environments[local.primary_env].argocd.app_of_apps_path }
      Project         = { type = "String", default = local.environments[local.primary_env].argocd.project }
      Namespace       = { type = "String", default = "argocd" }
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
            "REGION='{{ Region }}'",
            "CLUSTER='{{ ClusterName }}'",
            "REPO_URL='{{ RepoURL }}'",
            "REPO_USER='{{ RepoUsername }}'",
            "PAT_PARAM='{{ RepoPatParam }}'",
            "APP_PATH='{{ AppPath }}'",
            "PROJECT='{{ Project }}'",
            "NS='{{ Namespace }}'",

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
  for_each = module.envs

  name = aws_ssm_document.argocd_wireup.name

  targets {
    key    = "tag:Name"
    values = ["${lower(local.effective_tenant)}-${local.effective_region}-${each.key}-bastion"]
  }

  parameters = {
    Region       = local.effective_region
    ClusterName  = each.value.eks_cluster_name
    RepoURL      = local.environments[each.key].argocd.repo_url
    RepoUsername = local.environments[each.key].argocd.repo_username
    RepoPatParam = local.environments[each.key].argocd.repo_pat_param_name
    AppPath      = local.environments[each.key].argocd.app_of_apps_path
    Project      = local.environments[each.key].argocd.project
    Namespace    = "argocd"
  }

  depends_on = [
    aws_ssm_association.install_argocd_now, # make sure Argo is installed first
  ]
}
