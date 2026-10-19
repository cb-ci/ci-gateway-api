# =============================================================================
# CLUSTER AUTOSCALER — replaces 03-installClusterAutoscaler.sh
# =============================================================================
# The IRSA role/policy live in 01-infra/irsa.tf. EKS auto-tags each managed
# node group's ASG for auto-discovery (k8s.io/cluster-autoscaler/<cluster>,
# k8s.io/cluster-autoscaler/enabled) whenever minSize != maxSize, which is
# already true for both the "controllers" and "agents" node groups in
# 01-infra/eks.tf — nothing further to tag here.

locals {
  # cluster-autoscaler releases track EKS minor versions 1:1; a mismatched
  # image is a common source of silent scaling failures.
  cluster_autoscaler_image_tag = var.cluster_autoscaler_image_tag != "" ? var.cluster_autoscaler_image_tag : "v${local.infra.cluster_version}.0"
}

resource "kubernetes_service_account" "cluster_autoscaler" {
  metadata {
    name      = "cluster-autoscaler"
    namespace = "kube-system"

    labels = {
      "app.kubernetes.io/name" = "cluster-autoscaler"
    }

    annotations = {
      "eks.amazonaws.com/role-arn" = local.infra.cluster_autoscaler_role_arn
    }
  }
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    autoDiscovery = {
      clusterName = local.cluster
    }
    awsRegion = local.region

    rbac = {
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.cluster_autoscaler.metadata[0].name
      }
    }

    image = {
      tag = local.cluster_autoscaler_image_tag
    }
  })]

  depends_on = [kubernetes_service_account.cluster_autoscaler]
}

# --- Supplemental RBAC for resource.k8s.io (Dynamic Resource Allocation) ----
# Newer cluster-autoscaler builds unconditionally watch DRA objects
# (ResourceSlice, DeviceClass, ResourceClaim, ResourceClaimTemplate, ... —
# used only if workloads actually request DRA resources), but chart 9.46.6's
# bundled ClusterRole predates that and doesn't grant any of it. Rather than
# allowlist DRA kinds one watch-error at a time, grant the whole API group
# read-only — harmless no-op if a future chart version already grants it.
resource "kubernetes_cluster_role" "cluster_autoscaler_dra" {
  metadata {
    name = "cluster-autoscaler-dra"
  }

  rule {
    api_groups = ["resource.k8s.io"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "cluster_autoscaler_dra" {
  metadata {
    name = "cluster-autoscaler-dra"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.cluster_autoscaler_dra.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.cluster_autoscaler.metadata[0].name
    namespace = "kube-system"
  }
}
