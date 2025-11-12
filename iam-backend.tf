locals {
  backend_cfg = local.environments[local.primary_env].backend
}

resource "aws_iam_user" "backend_app" {
  name = "${lower(local.effective_tenant)}-${local.primary_env}-backend"
}

data "aws_iam_policy_document" "backend_s3" {
  statement {
    sid     = "AllowBucketRW"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucketMultipartUploads"
    ]

    resources = [
      "arn:aws:s3:::${local.backend_cfg.s3_bucket}/*"
    ]
  }
}

resource "aws_iam_user_policy" "backend_s3" {
  name   = "${lower(local.effective_tenant)}-${local.primary_env}-backend-s3"
  user   = aws_iam_user.backend_app.name
  policy = data.aws_iam_policy_document.backend_s3.json
}

# Access key for the app (sensitive)
resource "aws_iam_access_key" "backend_app" {
  user = aws_iam_user.backend_app.name
}

# Persist keys to SSM so the SSM doc can read them
resource "aws_ssm_parameter" "backend_access_key_id" {
  name  = local.backend_cfg.aws_access_key_id
  type  = "String"
  value = aws_iam_access_key.backend_app.id
}

resource "aws_ssm_parameter" "backend_secret_access_key" {
  name  = local.backend_cfg.aws_secret_key
  type  = "SecureString"
  value = aws_iam_access_key.backend_app.secret
}
