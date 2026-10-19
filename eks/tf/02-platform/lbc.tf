# =============================================================================
# AWS LOAD BALANCER CONTROLLER — replaces 03-installAwsLbController.sh
# =============================================================================
# This was the component missing entirely from the original scripts: eksctl
# created the IRSA ServiceAccount but nothing installed the controller, so no
# Ingress was ever reconciled into an ALB.

resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }

    annotations = {
      "eks.amazonaws.com/role-arn" = local.infra.alb_controller_role_arn
    }
  }
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lbc_chart_version
  namespace  = "kube-system"

  # The chart ships the TargetGroupBinding CRDs as regular templates in recent
  # versions; skip_crds stays false so they are installed.
  values = [yamlencode({
    clusterName = local.cluster
    region      = local.region
    vpcId       = local.infra.vpc_id

    serviceAccount = {
      create = false
      name   = kubernetes_service_account.alb_controller.metadata[0].name
    }

    createIngressClassResource = true
    ingressClass               = "alb"
  })]

  depends_on = [kubernetes_service_account.alb_controller]
}
