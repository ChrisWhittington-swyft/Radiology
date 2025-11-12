########################
# AMI (AL2023 latest)
########################
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

########################
# Current Region
########################
data "aws_region" "current" {}
