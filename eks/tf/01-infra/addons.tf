# =============================================================================
# MANAGED ADD-ONS — replaces the `addons:` block of eksctl-config.yaml
# =============================================================================
# eksctl installs vpc-cni / coredns / kube-proxy implicitly; they are declared
# explicitly here so the plan shows everything running in the cluster.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags
}

# CoreDNS runs as pods, so it needs schedulable nodes before it reports healthy.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags

  depends_on = [aws_eks_node_group.agents, aws_eks_node_group.system]
}

# Runs the Pod Identity Agent DaemonSet that the external-dns pod identity
# association depends on.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags

  depends_on = [aws_eks_node_group.agents, aws_eks_node_group.system]
}

# Both CSI driver *controller* Deployments (the external-attacher/
# provisioner sidecars) don't tolerate custom taints by default — only the
# per-node DaemonSet does. Now that "controllers" and "agents" are both
# tainted, they need an explicit toleration to land on "system" (or any
# other node) or every PVC attach/provision request times out with no
# attacher available to service it. The CriticalAddonsOnly/NoExecute entries
# are the addon's own defaults, restated here because configuration_values
# replaces the whole tolerations list rather than appending to it.
locals {
  csi_controller_tolerations = {
    controller = {
      tolerations = [
        { key = "CriticalAddonsOnly", operator = "Exists" },
        { effect = "NoExecute", operator = "Exists", tolerationSeconds = 300 },
        { key = "workload", operator = "Exists", effect = "NoSchedule" },
      ]
    }
  }
}

# ReadWriteOnce block storage for stateful CloudBees CI controller pods.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.irsa["ebs_csi"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values        = jsonencode(local.csi_controller_tolerations)
  tags                        = local.tags

  depends_on = [aws_eks_node_group.agents, aws_eks_node_group.system]
}

# ReadWriteMany shared storage — backs the efs-sc StorageClass in 02-platform.
# NOT yet verified against this addon's own configurationSchema — its chart
# may not share aws-ebs-csi-driver's exact shape. Run
# `aws eks describe-addon-configuration --addon-name aws-efs-csi-driver` and
# confirm the controller.tolerations path before relying on this.
resource "aws_eks_addon" "efs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-efs-csi-driver"
  service_account_role_arn    = aws_iam_role.irsa["efs_csi"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values        = jsonencode(local.csi_controller_tolerations)
  tags                        = local.tags

  depends_on = [aws_eks_node_group.agents, aws_eks_node_group.system]
}
