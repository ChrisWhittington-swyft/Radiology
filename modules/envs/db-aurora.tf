resource "random_password" "db_master" {
  length           = 20
  special          = true
  min_special      = 4
  override_special = "!#$%?"
}

resource "aws_kms_key" "secrets" {
  description             = "KMS key for Secrets Manager secrets"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = local.tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name_prefix}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_secretsmanager_secret" "db_master" {
  name       = "${local.name_prefix}-aurora-master"
  kms_key_id = aws_kms_key.secrets.arn
  tags       = local.tags
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id     = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_master.result
  })
}

resource "aws_db_subnet_group" "aurora" {
  name       = "${local.name_prefix}-aurora-subnets"
  subnet_ids = var.private_subnet_ids
  tags       = local.tags
}

# SG allowing Postgres only from EKS node group SG (tight)
resource "aws_security_group" "aurora" {
  name        = "${local.name_prefix}-aurora-sg"
  description = "Aurora PostgreSQL access from EKS nodes"
  vpc_id      = var.vpc_id
  tags = merge(local.tags, { Name = "${local.name_prefix}-aurora-sg" })
}

resource "aws_security_group_rule" "aurora_ingress_eks_nodes" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora.id
  source_security_group_id = module.eks.node_security_group_id
}

resource "aws_security_group_rule" "aurora_ingress_bastion" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora.id
  source_security_group_id = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "aurora_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.aurora.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_rds_cluster" "this" {
  cluster_identifier         = "${local.name_prefix}-aurora"
  engine                     = "aurora-postgresql"
  engine_version             = var.db_engine_version
  database_name              = var.db_name
  master_username            = var.db_username
  master_password            = jsondecode(aws_secretsmanager_secret_version.db_master.secret_string).password

  db_subnet_group_name       = aws_db_subnet_group.aurora.name
  vpc_security_group_ids     = [aws_security_group.aurora.id]

  # Serverless v2
  engine_mode = "provisioned"
  serverlessv2_scaling_configuration {
    min_capacity = var.serverlessv2_min_capacity_acus
    max_capacity = var.serverlessv2_max_capacity_acus
  }
  delete_automated_backups  = false
  skip_final_snapshot       = true
  final_snapshot_identifier = "${local.name_prefix}-final"
  backup_retention_period   = 30
  deletion_protection       = false
  storage_encrypted         = true
  copy_tags_to_snapshot     = true
  tags                      = local.tags
}

resource "aws_rds_cluster_instance" "this" {
  count               = 1
  identifier          = "${local.name_prefix}-aurora-0"
  cluster_identifier  = aws_rds_cluster.this.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.this.engine
  engine_version      = aws_rds_cluster.this.engine_version
  publicly_accessible = false
  tags                = local.tags
}
