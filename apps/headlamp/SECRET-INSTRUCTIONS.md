# Headlamp AWS Cognito Setup

The Cognito User Pool, App Client, and Kubernetes secret are **automatically created by Terraform**.

## What Terraform Does Automatically:

1. **Creates Cognito User Pool** (`cognito-headlamp.tf`):
   - Pool name: `vytalmed-prod-headlamp`
   - Configured for email-based login
   - Password policy enforced

2. **Creates Cognito User Pool Domain**:
   - Domain: `vytalmed-headlamp.auth.us-east-1.amazoncognito.com`

3. **Creates App Client**:
   - Name: `headlamp`
   - Generates client secret automatically
   - OAuth callback: `https://headlamp.prod.vytalmed.app/oidc-callback`

4. **Stores Client Secret in Secrets Manager**:
   - Secret name: `vytalmed-prod-headlamp-cognito-secret`

5. **SSM Document Creates K8s Secret** (`ssm-backend-secrets.tf`):
   - Runs on bastion after `terraform apply`
   - Creates `headlamp/headlamp-oidc` secret with:
     - `clientSecret`
     - `clientId`
     - `issuerUrl`

## What You Need to Do:

### 1. Apply Terraform

```bash
terraform apply
```

This creates everything automatically.

### 2. Create Users in Cognito

You need to manually create users who can access Headlamp:

```bash
# Get the User Pool ID from Terraform output
POOL_ID=$(terraform output -raw headlamp_cognito_user_pool_id)

# Create an admin user
aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username admin@yourcompany.com \
  --user-attributes Name=email,Value=admin@yourcompany.com Name=email_verified,Value=true \
  --temporary-password TempPass123! \
  --region us-east-1
```

The user will be prompted to change their password on first login.

### 3. Access Headlamp

Once ArgoCD deploys Headlamp:

1. Navigate to `https://headlamp.prod.vytalmed.app`
2. Click "Sign in with OIDC"
3. Log in with your Cognito credentials

## Terraform Outputs

View Cognito details:

```bash
terraform output headlamp_cognito_user_pool_id
terraform output headlamp_cognito_client_id
terraform output headlamp_cognito_issuer_url
terraform output headlamp_cognito_secret_arn
```

## Troubleshooting

### Check if K8s secret exists:
```bash
kubectl -n headlamp get secret headlamp-oidc -o yaml
```

### View secret values:
```bash
kubectl -n headlamp get secret headlamp-oidc -o jsonpath='{.data.clientId}' | base64 -d
kubectl -n headlamp get secret headlamp-oidc -o jsonpath='{.data.issuerUrl}' | base64 -d
```

### Re-run the SSM document manually:
```bash
aws ssm send-command \
  --document-name "backend-create-secret" \
  --targets "Key=tag:Name,Values=vytalmed-us-east-1-bastion" \
  --region us-east-1
```

### Check SSM document execution:
```bash
# Get command ID from send-command output
aws ssm get-command-invocation \
  --command-id <command-id> \
  --instance-id <instance-id> \
  --region us-east-1
```

### List Cognito users:
```bash
POOL_ID=$(terraform output -raw headlamp_cognito_user_pool_id)
aws cognito-idp list-users --user-pool-id "$POOL_ID" --region us-east-1
```

### Delete a user:
```bash
aws cognito-idp admin-delete-user \
  --user-pool-id "$POOL_ID" \
  --username admin@yourcompany.com \
  --region us-east-1
```

## Notes

- The SSM document (`backend-create-secret`) handles **both** backend secrets AND headlamp secrets
- If Cognito params are empty, it skips creating the headlamp secret (no errors)
- The callback URL is automatically set based on your app domain
- Users must verify their email on first login (temporary password flow)
