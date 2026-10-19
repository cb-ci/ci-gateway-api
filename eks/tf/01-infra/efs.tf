# =============================================================================
# EFS — replaces 02-create-efs-filesystem.sh (AWS-side resources only)
# =============================================================================
# The StorageClass and the test PVC/Pod from that script live in 02-platform
# (StorageClass) and are dropped entirely (test PVC/Pod — see tf/README.md).

resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs-sg"
  description = "Allow NFS (2049) from ${var.cluster_name} nodes to EFS mount targets"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.tags, { Name = "${var.cluster_name}-efs-sg" })
}

# Source is the EKS-managed cluster security group, which every managed node
# group member carries — same as the original script's --source-group.
resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from cluster nodes"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

resource "aws_efs_file_system" "this" {
  creation_token   = "${var.cluster_name}-efs"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true

  tags = merge(local.tags, { Name = "${var.cluster_name}-efs" })
}

# One mount target per private subnet. The original script created these in
# every private subnet it found, so this matches — but note that only node_az
# actually runs compute, so the others exist purely for future expansion.
resource "aws_efs_mount_target" "this" {
  for_each = toset(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}
