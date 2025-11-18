########################
# EC2 instance (Linux)
########################
resource "aws_instance" "bastion" {
  count                       = var.enable_bastion ? 1 : 0
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.bastion_instance_type
  subnet_id                   = local.bastion_subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name
  associate_public_ip_address = var.bastion_public
  key_name                    = var.bastion_keypair
  user_data                   = local.bastion_user_data
  user_data_replace_on_change = true

  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(local.tags, { Name = "${lower(var.tenant_name)}-${var.region}-${var.env_name}-bastion-linux" })
}

########################
# EC2 instance (Windows)
########################
resource "aws_instance" "bastion_windows" {
  count                       = var.enable_bastion && var.bastion_keypair != null ? 1 : 0
  ami                         = data.aws_ssm_parameter.windows_2022_ami.value
  instance_type               = var.bastion_instance_type
  subnet_id                   = local.bastion_subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name
  associate_public_ip_address = var.bastion_public
  key_name                    = var.bastion_keypair
  user_data                   = local.bastion_windows_user_data
  user_data_replace_on_change = true
  get_password_data           = true

  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(local.tags, { Name = "${lower(var.tenant_name)}-${var.region}-${var.env_name}-bastion-windows" })
}

########################
# Subnet selection & User data
########################
locals {
  bastion_subnet_id = var.bastion_public ? var.public_subnet_ids[0] : var.private_subnet_ids[0]

  bastion_user_data = <<-EOF
    #!/usr/bin/env bash
    set -euo pipefail
    dnf -y update
    dnf -y install jq git unzip
    dnf -y install postgresql15

    # kubectl (match EKS minor)
    KUBECTL_VER="$(curl -fsSL "https://dl.k8s.io/release/stable-${var.cluster_version}.txt")"
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$${KUBECTL_VER}/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl
    /usr/local/bin/kubectl version --client

    # Helm
    HELM_VER="v3.15.3"
    curl -fsSL "https://get.helm.sh/helm-$${HELM_VER}-linux-amd64.tar.gz" | tar xz
    install -m 0755 linux-amd64/helm /usr/local/bin/helm
    rm -rf linux-amd64
    helm version

    # eksctl
    curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" \
      | tar xz -C /usr/local/bin
    chmod +x /usr/local/bin/eksctl
    /usr/local/bin/eksctl version || true

    echo "Bastion bootstrap complete."
  EOF

  bastion_windows_user_data = <<-EOF
    <powershell>
    # Set execution policy
    Set-ExecutionPolicy Bypass -Scope Process -Force

    # Install Chocolatey
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

    # Install tools via Chocolatey
    choco install -y git
    choco install -y postgresql15 --params '/Password:Pass1234'
    choco install -y awscli
    choco install -y kubernetes-cli
    choco install -y kubernetes-helm

    # Install eksctl
    $eksctlVersion = (Invoke-WebRequest -Uri "https://api.github.com/repos/eksctl-io/eksctl/releases/latest" -UseBasicParsing | ConvertFrom-Json).tag_name.TrimStart('v')
    Invoke-WebRequest -Uri "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Windows_amd64.zip" -OutFile "$env:TEMP\eksctl.zip"
    Expand-Archive -Path "$env:TEMP\eksctl.zip" -DestinationPath "C:\Program Files\eksctl" -Force
    $env:Path += ";C:\Program Files\eksctl"
    [Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)

    # Refresh environment
    $env:ChocolateyInstall = Convert-Path "$((Get-Command choco).Path)\..\.."
    Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
    refreshenv

    Write-Host "Windows bastion bootstrap complete."
    </powershell>
  EOF
}

