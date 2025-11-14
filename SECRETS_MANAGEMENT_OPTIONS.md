# Secrets Management Options

This repo now supports three ways to manage secrets in Kubernetes:

## Option 1: Current Method (SSM Document → kubectl)

**How it works:**
- Terraform manages non-sensitive values
- Platform team manually sets sensitive SSM params once
- SSM document reads params and runs `kubectl create secret`

**Pros:**
- ✅ Everything centralized in Terraform
- ✅ Platform team owns all config
- ✅ Already working

**Cons:**
- ❌ Application config lives in Terraform, not app repos
- ❌ Direct cluster mutation (less GitOps)

**Example:** See `ssm-backend-secrets.tf`

---

## Option 2: Secrets Store CSI Driver (NEW)

**How it works:**
- Platform team manually sets SSM params once (same as Option 1)
- App team adds `SecretProviderClass` YAML to their repo
- Pods mount secrets as files via CSI volume
- Optionally sync to K8s Secret for env vars

**Install:**
```bash
terraform apply  # Applies ssm-secrets-store-csi.tf
```

**Developer Workflow:**

### Step 1: Platform sets SSM parameter (one-time)
```bash
aws ssm put-parameter \
  --name "/app/twilio/account_sid" \
  --type "String" \
  --value "ACxxxx" \
  --region us-east-1

aws ssm put-parameter \
  --name "/app/twilio/auth_token" \
  --type "SecureString" \
  --value "xxxx" \
  --region us-east-1
```

### Step 2: Developer adds YAML to their app repo

**File: `k8s/secret-provider.yaml`**
```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: twilio-secrets
  namespace: default
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "/app/twilio/account_sid"
        objectType: "ssmparameter"
      - objectName: "/app/twilio/auth_token"
        objectType: "ssmparameter"
  # Sync to K8s Secret for env var usage
  secretObjects:
  - secretName: twilio-secrets
    type: Opaque
    data:
    - objectName: "/app/twilio/account_sid"
      key: TWILIO_ACCOUNT_SID
    - objectName: "/app/twilio/auth_token"
      key: TWILIO_AUTH_TOKEN
```

**File: `k8s/deployment.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      serviceAccountName: backend-sa  # Must have SSM read permissions
      containers:
      - name: app
        image: my-app:latest
        # Option A: Use as files
        volumeMounts:
        - name: secrets
          mountPath: "/mnt/secrets"
          readOnly: true
        # Option B: Use as env vars (requires secretObjects above)
        envFrom:
        - secretRef:
            name: twilio-secrets
      volumes:
      - name: secrets
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: twilio-secrets
```

### Step 3: ArgoCD syncs it
```bash
git add k8s/secret-provider.yaml k8s/deployment.yaml
git commit -m "Add Twilio secrets"
git push
# ArgoCD auto-syncs, app gets secrets
```

**Pros:**
- ✅ App teams own their config in Git
- ✅ No kubectl commands needed
- ✅ Secrets auto-rotate when updated in SSM
- ✅ IAM controls who can read what

**Cons:**
- ❌ More YAML to write
- ❌ Pods must have IAM permissions (IRSA)
- ❌ Manual SSM param entry still required

---

## Option 3: External Secrets Operator (MOST GitOps)

**How it works:**
- Platform team manually sets SSM params once (same as others)
- App team adds `ExternalSecret` YAML to their repo
- Operator syncs SSM → K8s Secret automatically
- Apps consume standard K8s Secrets

**Install:**
```bash
terraform apply  # Applies ssm-external-secrets.tf
```

**Developer Workflow:**

### Step 1: Platform creates SecretStore (one-time per namespace)

**File: `argocd/base/secret-store.yaml`**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-ssm
  namespace: default
spec:
  provider:
    aws:
      service: ParameterStore
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: backend-sa  # Must have SSM read permissions
```

### Step 2: Developer adds ExternalSecret to their repo

**File: `k8s/external-secret.yaml`**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: twilio-secrets
  namespace: default
spec:
  refreshInterval: 1h  # Auto-refresh from SSM
  secretStoreRef:
    name: aws-ssm
    kind: SecretStore
  target:
    name: twilio-secrets  # K8s Secret name to create
    creationPolicy: Owner
  data:
  - secretKey: TWILIO_ACCOUNT_SID
    remoteRef:
      key: /app/twilio/account_sid
  - secretKey: TWILIO_AUTH_TOKEN
    remoteRef:
      key: /app/twilio/auth_token
```

### Step 3: Use in Deployment

**File: `k8s/deployment.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
      - name: app
        image: my-app:latest
        envFrom:
        - secretRef:
            name: twilio-secrets  # Standard K8s Secret
```

### Step 4: ArgoCD syncs it
```bash
git add k8s/external-secret.yaml k8s/deployment.yaml
git commit -m "Add Twilio secrets"
git push
# ArgoCD syncs → Operator creates K8s Secret → App uses it
```

**Pros:**
- ✅ Pure GitOps - all config in Git
- ✅ Standard K8s Secrets (no special volumes)
- ✅ Auto-refresh from SSM
- ✅ Can sync from multiple backends (SSM, Secrets Manager, etc)
- ✅ Best separation: Platform owns SecretStore, Devs own ExternalSecret

**Cons:**
- ❌ One more operator to run
- ❌ Manual SSM param entry still required
- ❌ Pods need IAM permissions (IRSA)

---

## Comparison

| Feature | Current Method | CSI Driver | External Secrets |
|---------|---------------|------------|------------------|
| **Manual SSM entry** | ✅ Required | ✅ Required | ✅ Required |
| **Config in Git** | ❌ In Terraform | ✅ In app repo | ✅ In app repo |
| **GitOps friendly** | ❌ Direct kubectl | ⚠️ Partial | ✅ Full |
| **Auto-refresh** | ❌ Manual re-run | ✅ Yes | ✅ Yes |
| **IAM required** | ❌ No | ✅ Yes (IRSA) | ✅ Yes (IRSA) |
| **Complexity** | Low | Medium | Medium |
| **Devs own config** | ❌ No | ✅ Yes | ✅ Yes |

---

## IAM Requirements for Options 2 & 3

Both CSI Driver and External Secrets require pod IAM permissions via IRSA.

**Add to `modules/envs/iam.tf`:**

```hcl
# IAM policy for SSM parameter read
data "aws_iam_policy_document" "ssm_read_secrets" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath"
    ]
    resources = [
      "arn:aws:ssm:${var.region}:${var.account_id}:parameter/app/*",
      "arn:aws:ssm:${var.region}:${var.account_id}:parameter/bootstrap/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt"
    ]
    resources = ["*"]  # Or specific KMS key for SecureString params
  }
}

resource "aws_iam_policy" "ssm_read_secrets" {
  name   = "${local.cluster_name}-ssm-read-secrets"
  policy = data.aws_iam_policy_document.ssm_read_secrets.json
}

# Attach to backend service account
resource "aws_iam_role_policy_attachment" "backend_ssm_read" {
  role       = module.backend_irsa.iam_role_name  # Your existing backend IRSA role
  policy_arn = aws_iam_policy.ssm_read_secrets.arn
}
```

---

## Recommendation

**For your setup:**

1. **Keep Option 1 (current)** for infrastructure secrets managed by platform team
2. **Add Option 3 (External Secrets)** for application secrets that devs want to manage in their repos

**Why External Secrets over CSI Driver?**
- Devs use familiar K8s Secrets (no special volumes)
- Better fit for ArgoCD GitOps workflow
- Platform creates SecretStore once, devs manage their own ExternalSecrets
- Industry momentum (more active development)

**Migration path:**
1. Install External Secrets with `terraform apply`
2. Create SecretStore in ArgoCD base config
3. Gradually migrate apps from Option 1 to Option 3
4. Keep Option 1 for system-level secrets (DB, Redis, etc)
