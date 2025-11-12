output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "db_writer_endpoint" {
  value = aws_rds_cluster.this.endpoint
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "db_secret_arn" {
  value     = aws_secretsmanager_secret.db_master.arn
  sensitive = true
}

output "cluster_sg_id" {
  value = module.eks.cluster_security_group_id
}

output "node_sg_id" {
  value = module.eks.node_security_group_id
}

output "cluster_ca" {
  value = module.eks.cluster_certificate_authority_data
}

output "enabled_env" {
  value = var.env_name
}

output "bastion_instance_id" {
  value       = try(aws_instance.bastion[0].id, null)
  description = "Bastion instance ID"
}

output "bastion_private_ip" {
  value       = try(aws_instance.bastion[0].private_ip, null)
  description = "Bastion private IP"
}

output "bastion_public_ip" {
  value       = var.bastion_public ? try(aws_instance.bastion[0].public_ip, null) : null
  description = "Bastion public IP (only if bastion_public=true)"
}

output "eks_cluster_name" {
  value       = module.eks.cluster_name  # terraform-aws-eks module output
  description = "EKS cluster name"
}

# Karpenter outputs
output "karpenter_controller_role_arn" {
  description = "IAM role ARN for Karpenter controller"
  value       = try(aws_iam_role.karpenter_controller[0].arn, null)
}

output "karpenter_node_role_arn" {
  description = "IAM role ARN for Karpenter nodes"
  value       = try(aws_iam_role.karpenter_node[0].arn, null)
}

output "karpenter_node_instance_profile" {
  description = "Instance profile name for Karpenter nodes"
  value       = try(aws_iam_instance_profile.karpenter_node[0].name, null)
}

output "karpenter_queue_name" {
  description = "SQS queue name for Karpenter interruption handling"
  value       = try(aws_sqs_queue.karpenter[0].name, null)
}

output "karpenter_enabled" {
  description = "Whether Karpenter is enabled for this environment"
  value       = local.karpenter_enabled
}
