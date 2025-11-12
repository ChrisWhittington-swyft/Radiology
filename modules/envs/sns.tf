resource "aws_sns_topic" "account_alerts_topic" {
  name = "Account_Alerts"

  lambda_success_feedback_sample_rate = 100
  lambda_failure_feedback_role_arn    = aws_iam_role.sns_logs.arn
  lambda_success_feedback_role_arn    = aws_iam_role.sns_logs.arn

  tags = {
    Name = "${var.tenant_name}-sns-alerts"
  }
}

resource "aws_sns_topic_subscription" "email_alerts" {
  for_each = toset(var.alerts_email)

  topic_arn = aws_sns_topic.account_alerts_topic.arn
  protocol  = "email"
  endpoint  = each.value
}


# Create an IAM role for the SNS with access to CloudWatch
resource "aws_iam_role" "sns_logs" {
  name = "sns-logs"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "sns.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

# Allow SNS to write logs to CloudWatch
resource "aws_iam_role_policy_attachment" "sns_logs" {
  role       = aws_iam_role.sns_logs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonSNSRole"
}


