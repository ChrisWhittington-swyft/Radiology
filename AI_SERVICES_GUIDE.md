# AI Services Guide (Textract & Bedrock)

## Overview

All pods running on your EKS cluster now have permissions to call:
- ✅ **Amazon Textract** - Document processing (OCR, forms, tables, IDs)
- ✅ **Amazon Bedrock** - AI models (Claude, Titan, Llama)

**No configuration needed** - just use the AWS SDK in your code.

## How It Works

IAM policies are attached to the EKS node role (same pattern as your Kafka setup):
- `modules/envs/ai-services.tf` - Textract and Bedrock policies
- Attached to: `module.eks.eks_managed_node_groups["main"].iam_role_name`
- All pods on the nodes inherit these permissions

## Using in Your Code

### Node.js / JavaScript

```javascript
import { TextractClient, AnalyzeDocumentCommand } from "@aws-sdk/client-textract";
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";

// SDK automatically uses node role credentials
const textract = new TextractClient({ region: "us-east-1" });
const bedrock = new BedrockRuntimeClient({ region: "us-east-1" });

// Example: Extract text from PDF in S3
const textractResponse = await textract.send(new AnalyzeDocumentCommand({
  Document: {
    S3Object: {
      Bucket: "vytalmed-prod-us-east-1",
      Name: "documents/patient-intake.pdf"
    }
  },
  FeatureTypes: ["FORMS", "TABLES"]
}));

// Example: Call Claude via Bedrock
const bedrockResponse = await bedrock.send(new InvokeModelCommand({
  modelId: "anthropic.claude-3-sonnet-20240229-v1:0",
  body: JSON.stringify({
    anthropic_version: "bedrock-2023-05-31",
    messages: [
      { role: "user", content: "Summarize this medical record..." }
    ],
    max_tokens: 1000
  })
}));

const result = JSON.parse(new TextDecoder().decode(bedrockResponse.body));
console.log(result.content[0].text);
```

### Java / Spring Boot

```java
import software.amazon.awssdk.services.textract.TextractClient;
import software.amazon.awssdk.services.bedrockruntime.BedrockRuntimeClient;
import software.amazon.awssdk.services.textract.model.*;

// SDK automatically uses node role credentials
TextractClient textract = TextractClient.builder()
    .region(Region.US_EAST_1)
    .build();

BedrockRuntimeClient bedrock = BedrockRuntimeClient.builder()
    .region(Region.US_EAST_1)
    .build();

// Example: Analyze document
AnalyzeDocumentRequest request = AnalyzeDocumentRequest.builder()
    .document(Document.builder()
        .s3Object(S3Object.builder()
            .bucket("vytalmed-prod-us-east-1")
            .name("documents/patient-intake.pdf")
            .build())
        .build())
    .featureTypes(FeatureType.FORMS, FeatureType.TABLES)
    .build();

AnalyzeDocumentResponse response = textract.analyzeDocument(request);
```

### Python

```python
import boto3
import json

# SDK automatically uses node role credentials
textract = boto3.client('textract', region_name='us-east-1')
bedrock = boto3.client('bedrock-runtime', region_name='us-east-1')

# Example: Analyze document
response = textract.analyze_document(
    Document={
        'S3Object': {
            'Bucket': 'vytalmed-prod-us-east-1',
            'Name': 'documents/patient-intake.pdf'
        }
    },
    FeatureTypes=['FORMS', 'TABLES']
)

# Example: Call Bedrock
response = bedrock.invoke_model(
    modelId='anthropic.claude-3-sonnet-20240229-v1:0',
    body=json.dumps({
        'anthropic_version': 'bedrock-2023-05-31',
        'messages': [
            {'role': 'user', 'content': 'Hello'}
        ],
        'max_tokens': 1000
    })
)
```

## Common Use Cases

### 1. Extract Text from Fax/PDF (Textract)

```javascript
async function extractTextFromFax(s3Bucket, s3Key) {
  const textract = new TextractClient({ region: "us-east-1" });

  const response = await textract.send(new AnalyzeDocumentCommand({
    Document: { S3Object: { Bucket: s3Bucket, Name: s3Key } },
    FeatureTypes: ["FORMS", "TABLES"]
  }));

  // Get all text lines
  const text = response.Blocks
    .filter(block => block.BlockType === "LINE")
    .map(block => block.Text)
    .join("\n");

  return text;
}
```

### 2. Extract Data from ID Card (Textract)

```javascript
async function extractIdInfo(s3Bucket, s3Key) {
  const textract = new TextractClient({ region: "us-east-1" });

  const response = await textract.send(new AnalyzeIDCommand({
    DocumentPages: [{
      S3Object: { Bucket: s3Bucket, Name: s3Key }
    }]
  }));

  const fields = response.IdentityDocuments[0].IdentityDocumentFields;

  return {
    firstName: fields.find(f => f.Type.Text === "FIRST_NAME")?.ValueDetection.Text,
    lastName: fields.find(f => f.Type.Text === "LAST_NAME")?.ValueDetection.Text,
    dob: fields.find(f => f.Type.Text === "DATE_OF_BIRTH")?.ValueDetection.Text,
    address: fields.find(f => f.Type.Text === "ADDRESS")?.ValueDetection.Text
  };
}
```

### 3. AI Summarization (Bedrock - Claude)

```javascript
async function summarizeDocument(documentText) {
  const bedrock = new BedrockRuntimeClient({ region: "us-east-1" });

  const response = await bedrock.send(new InvokeModelCommand({
    modelId: "anthropic.claude-3-haiku-20240307-v1:0", // Fast, cheap model
    body: JSON.stringify({
      anthropic_version: "bedrock-2023-05-31",
      messages: [
        {
          role: "user",
          content: `Summarize this medical document in 3 bullet points:\n\n${documentText}`
        }
      ],
      max_tokens: 500,
      temperature: 0.3
    })
  }));

  const result = JSON.parse(new TextDecoder().decode(response.body));
  return result.content[0].text;
}
```

### 4. Extract Structured Data (Bedrock)

```javascript
async function extractPatientInfo(documentText) {
  const bedrock = new BedrockRuntimeClient({ region: "us-east-1" });

  const response = await bedrock.send(new InvokeModelCommand({
    modelId: "anthropic.claude-3-haiku-20240307-v1:0",
    body: JSON.stringify({
      anthropic_version: "bedrock-2023-05-31",
      messages: [
        {
          role: "user",
          content: `Extract patient information from this text and return ONLY valid JSON with these fields: name, dob, diagnosis, medications.\n\n${documentText}`
        }
      ],
      max_tokens: 500
    })
  }));

  const result = JSON.parse(new TextDecoder().decode(response.body));
  return JSON.parse(result.content[0].text);
}
```

## Available Bedrock Models

### Claude 3 (Anthropic) - Recommended
- `anthropic.claude-3-opus-20240229-v1:0` - Most capable, expensive
- `anthropic.claude-3-sonnet-20240229-v1:0` - Balanced ($3-15 per 1M tokens)
- `anthropic.claude-3-haiku-20240307-v1:0` - Fast, cheap ($0.25-1.25 per 1M tokens)

### Amazon Titan
- `amazon.titan-text-express-v1` - General purpose
- `amazon.titan-text-lite-v1` - Lightweight

### Meta Llama 2
- `meta.llama2-13b-chat-v1`
- `meta.llama2-70b-chat-v1`

**Important:** Bedrock is NOT available in all regions. Use `us-east-1` or `us-west-2` for best model availability.

## Pricing (as of 2024)

### Textract
- **Detect Text:** $1.50 per 1,000 pages
- **Forms/Tables:** $50 per 1,000 pages
- **Analyze Expense:** $50 per 1,000 pages
- **Analyze ID:** $10 per 1,000 pages

### Bedrock (Claude 3 Haiku - cheapest)
- **Input:** $0.25 per 1M tokens (~750K words)
- **Output:** $1.25 per 1M tokens

### Best Practices
- Cache Bedrock responses when possible
- Use Claude Haiku for simple tasks, Sonnet for complex
- Monitor costs with AWS Cost Explorer
- Set up billing alerts

## Testing

### From a Pod
```bash
# Exec into a pod
kubectl exec -it <pod-name> -n default -- bash

# Test AWS credentials
aws sts get-caller-identity

# Should show the node role ARN
# arn:aws:iam::ACCOUNT:assumed-role/ria-dev-nodes-eks-node-group/...

# List Bedrock models
aws bedrock list-foundation-models --region us-east-1

# Test Textract (requires document in S3)
aws textract detect-document-text \
  --document '{"S3Object":{"Bucket":"your-bucket","Name":"doc.pdf"}}' \
  --region us-east-1
```

### From Local Development

You'll need AWS credentials configured locally:
```bash
# Option 1: AWS CLI
aws configure

# Option 2: Environment variables
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
```

## Troubleshooting

### "AccessDeniedException"
Check that:
1. You're in `us-east-1` or `us-west-2` (Bedrock availability)
2. The policies are attached: Check `modules/envs/ai-services.tf`
3. Pod is running on EKS nodes (not Fargate without proper setup)

### "Region not found"
Always specify region explicitly:
```javascript
const client = new TextractClient({ region: "us-east-1" });
```

### "Model not found" (Bedrock)
Use correct model ID and region. See [Bedrock Model IDs](https://docs.aws.amazon.com/bedrock/latest/userguide/model-ids.html).

### Testing Permissions
```bash
# From within a pod
aws textract help
aws bedrock list-foundation-models --region us-east-1
```

## Security Notes

✅ All pods on the cluster have access to Textract and Bedrock
⚠️ Monitor usage to control costs
⚠️ Be careful with sensitive data sent to AI models
✅ All API calls are logged in CloudTrail

## Questions?

**Q: Do I need to configure anything in my deployment?**
No! Just use the AWS SDK, it will automatically use the node role.

**Q: Can I use this from Lambda?**
No, this is for EKS pods only. Lambda has its own execution role.

**Q: What about cost controls?**
Set up AWS Budgets and billing alerts. Monitor with Cost Explorer.

**Q: Can I restrict access to specific pods?**
Not with this approach. All pods have access. (Would need IRSA for per-pod permissions)

**Q: Does this work with Fargate?**
It works with EC2 node groups. Fargate requires IRSA setup.
