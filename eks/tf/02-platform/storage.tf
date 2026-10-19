# =============================================================================
# EFS STORAGECLASS — replaces step 6 of 02-create-efs-filesystem.sh
# =============================================================================
# Steps 1-5 of that script (VPC/subnet discovery, security group, file system,
# mount targets, IAM safety net) are now declarative in 01-infra/efs.tf.
# Step 7 (test PVC + busybox pod) is intentionally not carried over — see
# tf/README.md.

resource "kubernetes_storage_class" "efs" {
  metadata {
    name = var.storage_class_name

    labels = var.tags
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "Immediate"

  parameters = {
    # One EFS access point per PVC.
    provisioningMode = "efs-ap"
    fileSystemId     = local.infra.efs_id
    directoryPerms   = "700"
    gidRangeStart    = "1000"
    gidRangeEnd      = "2000"
    basePath         = "/dynamic_provisioning"
  }
}
