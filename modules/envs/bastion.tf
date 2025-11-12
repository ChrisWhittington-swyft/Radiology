########################
# EC2 instance
########################
resource "aws_instance" "bastion" {
  count                       = var.enable_bastion ? 1 : 0
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.bastion_instance_type
  subnet_id                   = local.bastion_subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion[0].name
  associate_public_ip_address = var.bastion_public
  user_data                   = local.bastion_user_data
  user_data_replace_on_change = true

    lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(local.tags, { Name = "${lower(var.tenant_name)}-${var.region}-bastion" })
}

########################
# Subnet selection
########################
locals {
  bastion_subnet_id = var.bastion_public ? var.public_subnet_ids[0] : var.private_subnet_ids[0]
}

########################
# User data (tools)
########################
locals {
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
}

