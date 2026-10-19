# =============================================================================
# EXTERNAL-DNS — replaces 06-installExternalDNS.sh
# =============================================================================
# The IAM policy, role and EKS Pod Identity association all live in
# 01-infra/irsa.tf. This module only installs the chart.

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version
  namespace  = var.namespace_external_dns

  values = [yamlencode({
    provider = "aws"

    aws = {
      region = local.region
    }

    # source=ingress, NOT gateway-httproute. The Envoy Service is a ClusterIP
    # behind the ALB, so the Gateway's status address is a private cluster IP —
    # the gateway-httproute source would publish A records pointing at an
    # unroutable address.
    sources = ["ingress"]

    policy        = "sync"
    registry      = "txt"
    txtOwnerId    = local.cluster
    domainFilters = [local.infra.route53_zone_domain]

    serviceAccount = {
      create = true
      # Name must match the Pod Identity association in 01-infra, otherwise the
      # pod starts fine but every Route53 call fails with AccessDenied.
      name = var.external_dns_service_account
    }

    env = [{
      name  = "AWS_STS_REGIONAL_ENDPOINTS"
      value = "regional"
    }]
  })]

  # Nothing to publish until the ALB Ingress exists.
  depends_on = [kubernetes_ingress_v1.cjoc_alb]
}
