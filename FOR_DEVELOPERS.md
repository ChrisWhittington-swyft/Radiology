# For Backend Developers: Using AWS Services from EKS

## TL;DR

Your backend pods can now call AWS Textract, Bedrock, S3, and Kafka without managing AWS access keys.

**Just add one line to your deployment:**
```yaml
serviceAccountName: backend-sa
```

## What You Need to Do

### 1. Update Your Deployment YAML

**Before:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vytalmed-backend
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: backend
        image: your-backend:v1.0
        # ...
```

**After:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vytalmed-backend
  namespace: default
spec:
  template:
    spec:
      serviceAccountName: backend-sa  # ← ADD THIS
      containers:
      - name: backend
        image: your-backend:v1.0
        # ...
```

### 2. Remove Any Hardcoded AWS Credentials

❌ **Don't do this:**
```javascript
const textract = new TextractClient({
  region: "us-east-1",
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID,
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY
  }
});
```

✅ **Do this instead:**
```javascript
// SDK automatically discovers IRSA credentials
const textract = new TextractClient({ region: "us-east-1" });
```

### 3. That's It!

No code changes needed. The AWS SDK automatically uses IRSA credentials.

## What Services Can You Use?

### Amazon Textract - Document Processing
```javascript
import { TextractClient, AnalyzeDocumentCommand } from "@aws-sdk/client-textract";

const textract = new TextractClient({ region: "us-east-1" });

// Analyze a document from S3
const response = await textract.send(new AnalyzeDocumentCommand({
  Document: {
    S3Object: {
      Bucket: "vytalmed-prod-us-east-1",
      Name: "incoming-faxes-lambda/document.pdf"
    }
  },
  FeatureTypes: ["FORMS", "TABLES"]
}));

console.log("Extracted text:", response.Blocks);
```

### Amazon Bedrock - AI Models
```javascript
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";

const bedrock = new BedrockRuntimeClient({ region: "us-east-1" });

// Call Claude 3 Sonnet
const response = await bedrock.send(new InvokeModelCommand({
  modelId: "anthropic.claude-3-sonnet-20240229-v1:0",
  contentType: "application/json",
  accept: "application/json",
  body: JSON.stringify({
    anthropic_version: "bedrock-2023-05-31",
    messages: [
      { role: "user", content: "Summarize this medical record..." }
    ],
    max_tokens: 1000,
    temperature: 0.7
  })
}));

const result = JSON.parse(new TextDecoder().decode(response.body));
console.log("AI response:", result.content[0].text);
```

### Amazon S3 - File Storage
```javascript
import { S3Client, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";

const s3 = new S3Client({ region: "us-east-1" });

// Upload a file
await s3.send(new PutObjectCommand({
  Bucket: "vytalmed-prod-us-east-1",
  Key: "uploads/file.pdf",
  Body: fileBuffer,
  ContentType: "application/pdf"
}));

// Download a file
const response = await s3.send(new GetObjectCommand({
  Bucket: "vytalmed-prod-us-east-1",
  Key: "uploads/file.pdf"
}));
```

## Common Use Cases

### 1. Process Incoming Fax (Textract)
```javascript
async function processFax(s3Key) {
  const textract = new TextractClient({ region: "us-east-1" });

  const response = await textract.send(new AnalyzeDocumentCommand({
    Document: { S3Object: { Bucket: "vytalmed-prod-us-east-1", Name: s3Key } },
    FeatureTypes: ["FORMS", "TABLES"]
  }));

  // Extract form fields
  const fields = response.Blocks
    .filter(block => block.BlockType === "KEY_VALUE_SET")
    .map(block => ({
      key: block.Key?.Text,
      value: block.Value?.Text
    }));

  return fields;
}
```

### 2. Summarize Medical Record (Bedrock)
```javascript
async function summarizeMedicalRecord(recordText) {
  const bedrock = new BedrockRuntimeClient({ region: "us-east-1" });

  const response = await bedrock.send(new InvokeModelCommand({
    modelId: "anthropic.claude-3-sonnet-20240229-v1:0",
    body: JSON.stringify({
      anthropic_version: "bedrock-2023-05-31",
      messages: [
        {
          role: "user",
          content: `Summarize this medical record in 3 bullet points:\n\n${recordText}`
        }
      ],
      max_tokens: 500
    })
  }));

  const result = JSON.parse(new TextDecoder().decode(response.body));
  return result.content[0].text;
}
```

### 3. Extract Data from ID Card (Textract)
```javascript
async function extractIdInfo(s3Key) {
  const textract = new TextractClient({ region: "us-east-1" });

  const response = await textract.send(new AnalyzeIDCommand({
    DocumentPages: [{
      S3Object: { Bucket: "vytalmed-prod-us-east-1", Name: s3Key }
    }]
  }));

  const fields = response.IdentityDocuments[0].IdentityDocumentFields;

  return {
    firstName: fields.find(f => f.Type.Text === "FIRST_NAME")?.ValueDetection.Text,
    lastName: fields.find(f => f.Type.Text === "LAST_NAME")?.ValueDetection.Text,
    dateOfBirth: fields.find(f => f.Type.Text === "DATE_OF_BIRTH")?.ValueDetection.Text,
    address: fields.find(f => f.Type.Text === "ADDRESS")?.ValueDetection.Text
  };
}
```

## Testing Locally vs. Production

### In EKS (Production)
- IRSA credentials auto-injected
- Just use SDK normally
- No configuration needed

### On Your Laptop (Development)
You'll need AWS credentials configured locally:

```bash
# Option 1: AWS CLI configured
aws configure

# Option 2: Environment variables
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
```

The SDK checks for credentials in this order:
1. Environment variables
2. IRSA (if running in EKS)
3. AWS credentials file (`~/.aws/credentials`)
4. EC2 instance metadata (if on EC2)

## Troubleshooting

### "AccessDeniedException"
**Problem:** Can't call AWS service

**Fix:** Make sure your deployment uses `serviceAccountName: backend-sa`

```bash
# Check if pod has the service account
kubectl get pod <pod-name> -o jsonpath='{.spec.serviceAccountName}'

# Should output: backend-sa
```

### "Region not found"
**Problem:** SDK doesn't know which region to use

**Fix:** Specify region explicitly:
```javascript
const client = new TextractClient({ region: "us-east-1" });
```

Or set environment variable in deployment:
```yaml
env:
- name: AWS_REGION
  value: us-east-1
```

### "No credentials found"
**Problem:** SDK can't find AWS credentials

**Fix:** Check that IRSA environment variables are injected:
```bash
kubectl exec -it <pod-name> -- env | grep AWS_

# Should show:
# AWS_ROLE_ARN=arn:aws:iam::...
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/...
```

If not showing, verify:
1. Deployment uses `serviceAccountName: backend-sa`
2. ServiceAccount exists: `kubectl get sa backend-sa -n default`
3. ServiceAccount has annotation: `kubectl get sa backend-sa -n default -o yaml`

## Cost Awareness

### Textract
- **Detect Text:** $1.50 per 1,000 pages
- **Forms/Tables:** $50 per 1,000 pages
- Use wisely! Cache results when possible

### Bedrock (Claude 3)
- **Sonnet:** ~$3-15 per 1M tokens
- **Haiku (cheaper):** ~$0.25-1.25 per 1M tokens
- Monitor token usage
- Use smaller context when possible

### S3
- **Storage:** $0.023 per GB/month
- **GET requests:** $0.0004 per 1,000
- Minimal cost for typical usage

## Available Bedrock Models

### Claude 3 (Anthropic) - Recommended
- `anthropic.claude-3-opus-20240229-v1:0` - Most capable, expensive
- `anthropic.claude-3-sonnet-20240229-v1:0` - Balanced
- `anthropic.claude-3-haiku-20240307-v1:0` - Fast, cheap

### Titan (AWS)
- `amazon.titan-text-express-v1` - General purpose
- `amazon.titan-text-lite-v1` - Lightweight

### Llama 2 (Meta)
- `meta.llama2-13b-chat-v1`
- `meta.llama2-70b-chat-v1`

Check [AWS Bedrock docs](https://docs.aws.amazon.com/bedrock/latest/userguide/model-ids.html) for latest models.

## Example: Complete Fax Processing Pipeline

```javascript
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { TextractClient, AnalyzeDocumentCommand } from "@aws-sdk/client-textract";
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";

async function processFax(s3Key) {
  // 1. Get file from S3
  const s3 = new S3Client({ region: "us-east-1" });
  const s3Response = await s3.send(new GetObjectCommand({
    Bucket: "vytalmed-prod-us-east-1",
    Key: s3Key
  }));

  // 2. Extract text with Textract
  const textract = new TextractClient({ region: "us-east-1" });
  const textractResponse = await textract.send(new AnalyzeDocumentCommand({
    Document: { S3Object: { Bucket: "vytalmed-prod-us-east-1", Name: s3Key } },
    FeatureTypes: ["FORMS", "TABLES"]
  }));

  // Extract all text
  const fullText = textractResponse.Blocks
    .filter(block => block.BlockType === "LINE")
    .map(block => block.Text)
    .join("\n");

  // 3. Analyze with Bedrock
  const bedrock = new BedrockRuntimeClient({ region: "us-east-1" });
  const bedrockResponse = await bedrock.send(new InvokeModelCommand({
    modelId: "anthropic.claude-3-haiku-20240307-v1:0",
    body: JSON.stringify({
      anthropic_version: "bedrock-2023-05-31",
      messages: [{
        role: "user",
        content: `Extract patient info from this fax:\n\n${fullText}\n\nReturn JSON: {name, dob, diagnosis}`
      }],
      max_tokens: 500
    })
  }));

  const result = JSON.parse(new TextDecoder().decode(bedrockResponse.body));
  const patientInfo = JSON.parse(result.content[0].text);

  // 4. Store in database (using your existing DB connection)
  await db.faxes.create({
    s3Key,
    patientName: patientInfo.name,
    dateOfBirth: patientInfo.dob,
    diagnosis: patientInfo.diagnosis,
    fullText,
    processedAt: new Date()
  });

  return patientInfo;
}
```

## Questions?

**Q: Do I need AWS credentials in my code?**
No! IRSA handles it automatically.

**Q: Can I test this locally?**
Yes, but you'll need AWS credentials configured on your laptop.

**Q: What if I need different permissions?**
Ask platform team to update `modules/envs/iam-backend.tf`.

**Q: Can other deployments use this?**
Yes! Any pod in `default` namespace can use `serviceAccountName: backend-sa`.

**Q: What about other namespaces?**
Ask platform team to create additional ServiceAccounts.

**Q: Is this secure?**
Yes! No credentials in code or config. Tokens expire automatically.
