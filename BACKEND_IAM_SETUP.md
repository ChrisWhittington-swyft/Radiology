# Backend IAM Setup (IRSA)

## Overview

The backend application pods now have IAM permissions to call AWS services via IRSA (IAM Roles for Service Accounts).

## What Was Added

### 1. IAM Role for Backend Pods (`modules/envs/iam-backend.tf`)

Created an IRSA role that pods can assume when they use the `backend-sa` ServiceAccount.

**Permissions included:**

#### Amazon Textract
- `textract:AnalyzeDocument` - Analyze documents (forms, tables, key-value pairs)
- `textract:AnalyzeExpense` - Extract data from invoices and receipts
- `textract:AnalyzeID` - Extract data from identity documents
- `textract:DetectDocumentText` - Basic text detection
- `textract:Start*` - Async document processing
- `textract:Get*` - Retrieve async results

#### Amazon Bedrock
- `bedrock:InvokeModel` - Call foundation models (Claude, Titan, etc)
- `bedrock:InvokeModelWithResponseStream` - Streaming responses
- `bedrock:GetFoundationModel` - Get model details
- `bedrock:ListFoundationModels` - List available models
- `bedrock:InvokeAgent` - Call Bedrock Agents
- `bedrock:Retrieve` - Query Knowledge Bases
- `bedrock:RetrieveAndGenerate` - RAG operations

#### Amazon S3
- Full access to the backend's S3 bucket (from `backend.s3_bucket` config)
- `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`

#### Amazon MSK (Kafka) - If Enabled
- Connect to the MSK Serverless cluster
- Create, read, write topics
- Manage consumer groups

### 2. Kubernetes ServiceAccount (`ssm-backend-serviceaccount.tf`)

Creates the `backend-sa` ServiceAccount in the `default` namespace with the IRSA role annotation.

**YAML equivalent:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-sa
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/CLUSTER-backend
```

### 3. Deployment Configuration

Your backend pods **MUST** use this ServiceAccount to get IAM permissions.

**Add to your backend Deployment YAML:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vytalmed-backend
  namespace: default
spec:
  template:
    spec:
      serviceAccountName: backend-sa  # ← REQUIRED
      containers:
      - name: backend
        image: your-backend-image
        # ... rest of your config
```

## How It Works

1. **Terraform creates:**
   - IAM role with trust policy for EKS OIDC provider
   - IAM policies for Textract, Bedrock, S3, Kafka
   - Kubernetes ServiceAccount with role annotation

2. **EKS injects credentials:**
   - When pod starts with `serviceAccountName: backend-sa`
   - EKS mutating webhook injects AWS credentials as environment variables
   - AWS SDK automatically uses these credentials

3. **Application calls AWS:**
   - No access keys needed in code
   - AWS SDK auto-discovers credentials
   - Permissions scoped to the IAM role

## Using in Your Application

### Node.js / JavaScript
```javascript
import { TextractClient, AnalyzeDocumentCommand } from "@aws-sdk/client-textract";
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";

// SDK automatically uses IRSA credentials
const textract = new TextractClient({ region: "us-east-1" });
const bedrock = new BedrockRuntimeClient({ region: "us-east-1" });

// Call Textract
const response = await textract.send(new AnalyzeDocumentCommand({
  Document: { S3Object: { Bucket: "...", Name: "..." } },
  FeatureTypes: ["FORMS", "TABLES"]
}));

// Call Bedrock
const bedrockResponse = await bedrock.send(new InvokeModelCommand({
  modelId: "anthropic.claude-3-sonnet-20240229-v1:0",
  body: JSON.stringify({
    anthropic_version: "bedrock-2023-05-31",
    messages: [{ role: "user", content: "Hello" }],
    max_tokens: 1000
  })
}));
```

### Java / Spring Boot
```java
import software.amazon.awssdk.services.textract.TextractClient;
import software.amazon.awssdk.services.bedrockruntime.BedrockRuntimeClient;

// SDK automatically uses IRSA credentials
TextractClient textract = TextractClient.builder()
    .region(Region.US_EAST_1)
    .build();

BedrockRuntimeClient bedrock = BedrockRuntimeClient.builder()
    .region(Region.US_EAST_1)
    .build();
```

### Python
```python
import boto3

# SDK automatically uses IRSA credentials
textract = boto3.client('textract', region_name='us-east-1')
bedrock = boto3.client('bedrock-runtime', region_name='us-east-1')

# Call Textract
response = textract.analyze_document(
    Document={'S3Object': {'Bucket': '...', 'Name': '...'}},
    FeatureTypes=['FORMS', 'TABLES']
)

# Call Bedrock
response = bedrock.invoke_model(
    modelId='anthropic.claude-3-sonnet-20240229-v1:0',
    body=json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "messages": [{"role": "user", "content": "Hello"}],
        "max_tokens": 1000
    })
)
```

## Environment Variables Available in Pods

When using `serviceAccountName: backend-sa`, these env vars are auto-injected:

```bash
AWS_ROLE_ARN=arn:aws:iam::ACCOUNT:role/CLUSTER-backend
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
AWS_REGION=us-east-1  # Or your configured region
```

The AWS SDK automatically detects and uses these.

## Verifying IRSA Works

### Check ServiceAccount
```bash
kubectl get serviceaccount backend-sa -n default -o yaml
```

Should show:
```yaml
metadata:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/CLUSTER-backend
```

### Check Pod Has Credentials
```bash
kubectl exec -it <backend-pod> -n default -- env | grep AWS_
```

Should show:
```
AWS_ROLE_ARN=arn:aws:iam::ACCOUNT:role/CLUSTER-backend
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
AWS_REGION=us-east-1
```

### Test AWS CLI in Pod
```bash
kubectl exec -it <backend-pod> -n default -- aws sts get-caller-identity
```

Should return:
```json
{
  "UserId": "AROA...:botocore-session-...",
  "Account": "123456789012",
  "Arn": "arn:aws:sts::123456789012:assumed-role/CLUSTER-backend/botocore-session-..."
}
```

## Troubleshooting

### "AccessDeniedException" or "UnauthorizedException"

**Problem:** Pod can't call AWS service

**Solutions:**
1. Verify pod uses `serviceAccountName: backend-sa`
2. Check IRSA role has required permissions: `modules/envs/iam-backend.tf`
3. Verify role ARN annotation on ServiceAccount
4. Check AWS SDK is using IRSA credentials (not hardcoded keys)

### "No credentials found"

**Problem:** AWS SDK can't find credentials

**Solutions:**
1. Verify ServiceAccount exists and has annotation
2. Check pod is using the ServiceAccount
3. Verify EKS OIDC provider is configured (should be automatic)
4. Check pod has injected env vars (`AWS_ROLE_ARN`, etc)

### "Region not specified"

**Problem:** SDK doesn't know which region to use

**Solutions:**
1. Set `AWS_REGION` env var in deployment
2. Or specify region in SDK client constructor
3. Or use `AWS_DEFAULT_REGION` env var

## Regions and Bedrock Availability

**Bedrock is NOT available in all regions.**

Common Bedrock regions:
- `us-east-1` (N. Virginia) ✅ Most models
- `us-west-2` (Oregon) ✅ Most models
- `eu-central-1` (Frankfurt) ✅ Limited models
- `ap-southeast-1` (Singapore) ✅ Limited models

If your EKS cluster is in `us-east-1`, you're good. Otherwise, you may need to create a Bedrock client in a different region than your cluster.

**Example for cross-region:**
```javascript
// Cluster in us-west-2, but Bedrock in us-east-1
const bedrock = new BedrockRuntimeClient({ region: "us-east-1" });
```

## Cost Considerations

### Textract Pricing (as of 2024)
- Detect Text: $1.50 per 1,000 pages
- Analyze Document (Forms/Tables): $50 per 1,000 pages
- Analyze Expense: $50 per 1,000 pages
- Analyze ID: $10 per 1,000 pages

### Bedrock Pricing (varies by model)
**Claude 3 Sonnet (example):**
- Input: $3 per 1M tokens
- Output: $15 per 1M tokens

**Claude 3 Haiku (cheaper):**
- Input: $0.25 per 1M tokens
- Output: $1.25 per 1M tokens

**Titan Text (AWS model):**
- Input: $0.30 per 1M tokens
- Output: $0.40 per 1M tokens

### Best Practices
1. Cache Bedrock responses when possible
2. Use async Textract for large batches
3. Monitor costs with AWS Cost Explorer
4. Set up billing alerts

## Security Notes

✅ **Good:**
- No AWS access keys in code or config
- Permissions scoped to specific role
- Easy to audit (CloudTrail logs show role usage)
- Can't be stolen if pod is compromised (tokens expire)

⚠️ **Be aware:**
- Bedrock models can be expensive
- Textract costs scale with document volume
- Monitor usage with AWS Budgets
- Review IAM policies regularly

## Deployment Steps

1. **Apply Terraform:**
   ```bash
   terraform apply
   ```

2. **Verify ServiceAccount created:**
   ```bash
   kubectl get sa backend-sa -n default
   ```

3. **Update your backend Deployment:**
   Add `serviceAccountName: backend-sa` to pod spec

4. **Redeploy backend:**
   ```bash
   kubectl rollout restart deployment/vytalmed-backend -n default
   ```

5. **Test from pod:**
   ```bash
   kubectl exec -it <pod> -- aws sts get-caller-identity
   ```

## Questions?

**Q: Can I use this from Lambda?**
No, this is for EKS pods only. Lambda has its own execution role.

**Q: Can multiple deployments use the same ServiceAccount?**
Yes! Any pod in `default` namespace can use `backend-sa`.

**Q: Can I restrict Bedrock to specific models?**
Yes, edit `modules/envs/iam-backend.tf` and replace `foundation-model/*` with specific model ARNs.

**Q: What about other namespaces?**
Create additional ServiceAccounts in other namespaces with the same role ARN annotation.

**Q: Does this work with Fargate?**
Yes, IRSA works with both EC2 and Fargate nodes.
