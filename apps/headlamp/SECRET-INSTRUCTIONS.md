# Headlamp AWS Cognito Setup Instructions

This secret is created automatically via the SSM document `ssm-headlamp-install.tf`.

## AWS Cognito Setup (One-time):

### 1. Create a Cognito User Pool

```bash
aws cognito-idp create-user-pool \
  --pool-name headlamp-users \
  --policies "PasswordPolicy={MinimumLength=8,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=false}" \
  --auto-verified-attributes email \
  --username-attributes email \
  --region us-east-1
```

**Note the User Pool ID** (e.g., `us-east-1_ABC123XYZ`)

### 2. Create a Cognito User Pool Domain

```bash
aws cognito-idp create-user-pool-domain \
  --domain headlamp-vytalmed \
  --user-pool-id us-east-1_ABC123XYZ \
  --region us-east-1
```

### 3. Create an App Client

```bash
aws cognito-idp create-user-pool-client \
  --user-pool-id us-east-1_ABC123XYZ \
  --client-name headlamp \
  --generate-secret \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid profile email \
  --callback-urls https://headlamp.ria-poc.nymbl.host/oidc-callback \
  --allowed-o-auth-flows-user-pool-client \
  --supported-identity-providers COGNITO \
  --region us-east-1
```

**Note the following from the output:**
- `ClientId`
- `ClientSecret`

### 4. Store the Client Secret in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name headlamp/cognito-client-secret \
  --secret-string 'YOUR_CLIENT_SECRET_HERE' \
  --region us-east-1
```

**Note the ARN** (e.g., `arn:aws:secretsmanager:us-east-1:123456789012:secret:headlamp/cognito-client-secret-AbCdEf`)

### 5. Update Terraform Configuration

Edit `instances.tf` and update the `headlamp` block in the `prod` environment:

```hcl
headlamp = {
  cognito_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:headlamp/cognito-client-secret-AbCdEf"
  cognito_client_id  = "YOUR_CLIENT_ID_HERE"
  cognito_issuer_url = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_ABC123XYZ"
}
```

### 6. Apply Terraform

```bash
terraform apply
```

This will:
- Create the SSM document `headlamp-create-secret`
- Run it on the bastion to create the K8s secret `headlamp/headlamp-oidc`
- Secret will contain: `clientSecret`, `clientId`, `issuerUrl`

### 7. Create a Test User

```bash
aws cognito-idp admin-create-user \
  --user-pool-id us-east-1_ABC123XYZ \
  --username admin@yourcompany.com \
  --user-attributes Name=email,Value=admin@yourcompany.com Name=email_verified,Value=true \
  --temporary-password TempPass123! \
  --region us-east-1
```

The user will be prompted to change their password on first login.

## Access Headlamp

Once deployed via ArgoCD:

1. Navigate to `https://headlamp.ria-poc.nymbl.host`
2. Click "Sign in with OIDC"
3. Log in with your Cognito credentials

## Troubleshooting

### Check if secret exists:
```bash
kubectl -n headlamp get secret headlamp-oidc -o yaml
```

### Re-run the SSM document manually:
```bash
aws ssm send-command \
  --document-name "headlamp-create-secret" \
  --targets "Key=tag:Name,Values=vytalmed-us-east-1-bastion" \
  --region us-east-1
```
