########################
# AMI (AL2023 latest)
########################
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

########################
# AMI (Windows Server 2022 latest)
########################
data "aws_ssm_parameter" "windows_2022_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

########################
# Current Region
########################
data "aws_region" "current" {}
