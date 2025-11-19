#Lambda us-east-1 Code Upload Bucket
#----------------------
    resource "aws_s3_bucket" "lambda_us-east-1_code_bucket" {
    bucket = "${lower(var.tenant_name)}-${lower(var.env_name)}-us-east-1-lambda-code"
  }
    resource "aws_s3_bucket_public_access_block" "lambda_us-east-1_code_bucket" {
    bucket = aws_s3_bucket.lambda_us-east-1_code_bucket.id
    block_public_acls   = true
    block_public_policy = true
    ignore_public_acls  = true
    restrict_public_buckets = true
  }



#Fax us-east-1 Bucket
#----------------------
    resource "aws_s3_bucket" "fax_us-east-1_code_bucket" {
    bucket = "${lower(var.tenant_name)}-${lower(var.env_name)}-us-east-1"
  }
    resource "aws_s3_bucket_public_access_block" "fax_us-east-1_code_bucket" {
    bucket = aws_s3_bucket.fax_us-east-1_code_bucket.id
    block_public_acls   = true
    block_public_policy = true
    ignore_public_acls  = true
    restrict_public_buckets = true
  }
