##############################
# Slack Alerts Lambda
##############################

locals {
  # where the code lives
  slack_src_dir  = "${path.module}/lambda/slack_alert_lambda"
  slack_zip_path = "${path.module}/lambda/slack_alert_lambda.zip"
}

# Package the function code into a zip
data "archive_file" "cloudwatch_alarms_to_slack" {
  count       = var.enable_slack_alerts ? 1 : 0
  type        = "zip"
  source_dir  = local.slack_src_dir
  output_path = local.slack_zip_path
}

# Upload the zip to the code bucket
resource "aws_s3_object" "slack_lambda_zip" {
  count  = var.enable_slack_alerts ? 1 : 0
  bucket = aws_s3_bucket.lambda_us-east-1_code_bucket.id
  key    = "slack-alert-lambda.zip"

  # Use the archive output so the graph enforces ordering
  source = data.archive_file.cloudwatch_alarms_to_slack[0].output_path
  etag   = data.archive_file.cloudwatch_alarms_to_slack[0].output_md5
}

# IAM role for the function
resource "aws_iam_role" "cloudwatch_alarms_to_slack" {
  count = var.enable_slack_alerts ? 1 : 0
  name  = "cloudwatch-alarms-to-slack"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Basic logging policy
resource "aws_iam_role_policy_attachment" "cloudwatch_alarms_to_slack_basic" {
  count      = var.enable_slack_alerts ? 1 : 0
  role       = aws_iam_role.cloudwatch_alarms_to_slack[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# The function
resource "aws_lambda_function" "cloudwatch_alarms_to_slack" {
  count         = var.enable_slack_alerts ? 1 : 0
  function_name = "cloudwatch-alarms-to-slack"

  s3_bucket = aws_s3_bucket.lambda_us-east-1_code_bucket.id
  s3_key    = aws_s3_object.slack_lambda_zip[0].key

  runtime = "python3.9"
  handler = "function.lambda_handler" # file: function.py, func: lambda_handler

  role = aws_iam_role.cloudwatch_alarms_to_slack[0].arn

  # Force updates when code changes
  source_code_hash = data.archive_file.cloudwatch_alarms_to_slack[0].output_base64sha256

  environment {
    variables = { SLACK_HOOK_URL = var.slack_hook_uri }
  }
}

# CloudWatch log group
resource "aws_cloudwatch_log_group" "cloudwatch_alarms_to_slack" {
  count             = var.enable_slack_alerts ? 1 : 0
  name              = "/aws/lambda/${aws_lambda_function.cloudwatch_alarms_to_slack[0].function_name}"
  retention_in_days = 14
}

# Allow SNS to invoke the function
resource "aws_lambda_permission" "sns_slack_alarms" {
  count         = var.enable_slack_alerts ? 1 : 0
  statement_id  = "AllowExecutionFromSNSAlarms"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cloudwatch_alarms_to_slack[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.account_alerts_topic.arn
}

# Subscribe lambda to the SNS topic
resource "aws_sns_topic_subscription" "slack_alarms" {
  count     = var.enable_slack_alerts ? 1 : 0
  topic_arn = aws_sns_topic.account_alerts_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cloudwatch_alarms_to_slack[0].arn
}
