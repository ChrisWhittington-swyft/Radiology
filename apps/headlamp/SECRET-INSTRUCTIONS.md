# Headlamp Azure AD Secret Setup

This secret is NOT stored in Git for security reasons.

## Azure AD Setup (One-time):

1. Go to Azure Portal → App Registrations → New Registration
   - Name: `Headlamp K8s Dashboard`
   - Redirect URI: `https://headlamp.ria-poc.nymbl.host/oidc-callback`
   - Click Register

2. Note the following values:
   - **Application (client) ID**: Copy this
   - **Directory (tenant) ID**: Copy this

3. Create a client secret:
   - Certificates & secrets → New client secret
   - Description: `Headlamp`
   - Copy the **Value** (not the Secret ID)

4. Update the ConfigMap and Deployment:
   - Replace `AZURE_AD_CLIENT_ID_PLACEHOLDER` with your Client ID
   - Replace `TENANT_ID_PLACEHOLDER` with your Tenant ID

## Create the Secret in K8s:

```bash
kubectl create secret generic headlamp-oidc \
  --namespace headlamp \
  --from-literal=clientSecret='YOUR_CLIENT_SECRET_HERE'
```

## OR Store in AWS Secrets Manager:

```bash
aws secretsmanager create-secret \
  --name headlamp/azure-ad-client-secret \
  --secret-string 'YOUR_CLIENT_SECRET_HERE'
```

Then use External Secrets Operator or manually sync to K8s.
