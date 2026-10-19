# =============================================================================
# ENVOY GATEWAY + ALB — replaces 04-installEnvoy.sh
# =============================================================================
# Topology:
#   Internet -> ALB (HTTPS:443, ACM cert) -> stable Service -> Envoy pods
#            -> Gateway -> HTTPRoute (from the CloudBees chart) -> CJOC

# --- CRDs (Gateway API standard channel + Envoy Gateway) ----------------------
# These CRDs can NOT be a helm_release: Helm stores the chart in a single
# release Secret and Kubernetes caps Secrets at 1 MiB, so the install fails with
# `Secret "sh.helm.release.v1.eg-crds...." Too long` (splitting into two
# releases does not help, since the whole chart is stored in each). Instead the
# chart is rendered at plan time and each CRD is applied server-side, like the
# bash version's `helm template ... | kubectl apply --server-side`. Server-side
# apply also avoids the oversized last-applied annotation that client-side
# apply puts on large CRDs.
data "helm_template" "envoy_gateway_crds" {
  name       = "eg-crds"
  repository = "oci://docker.io/envoyproxy"
  chart      = "gateway-crds-helm"
  version    = var.envoy_gateway_version
  namespace  = var.envoy_gw_namespace

  values = [yamlencode({
    crds = {
      gatewayAPI = {
        enabled = true
        channel = "standard"
      }
      envoyGateway = {
        enabled = true
      }
    }
  })]
}

data "kubectl_file_documents" "envoy_gateway_crds" {
  content = data.helm_template.envoy_gateway_crds.manifest
}

resource "kubectl_manifest" "envoy_gateway_crds" {
  # Keys are the documents' API paths, known at plan time.
  for_each  = data.kubectl_file_documents.envoy_gateway_crds.manifests
  yaml_body = each.value

  server_side_apply = true
  force_conflicts   = true
}

# --- Envoy Gateway controller -------------------------------------------------
resource "helm_release" "envoy_gateway" {
  name       = "eg"
  repository = "oci://docker.io/envoyproxy"
  chart      = "gateway-helm"
  version    = var.envoy_gateway_version
  namespace  = var.envoy_gw_namespace

  # The CRD step above is cluster-scoped, so this release owns the namespace.
  create_namespace = true
  skip_crds        = true

  # Envoy Gateway must be Available before any Gateway resource is accepted.
  wait    = true
  timeout = 600

  depends_on = [kubectl_manifest.envoy_gateway_crds]
}

# --- CloudBees namespace ------------------------------------------------------
resource "kubernetes_namespace" "cloudbees" {
  metadata {
    name = var.namespace_cloudbees

    labels = {
      "cloudbees.com/gateway-routes" = "enabled"
    }
  }
}

# --- EnvoyProxy: shape of the generated Envoy Service -------------------------
# ClusterIP, not LoadBalancer. The ALB reaches Envoy pods directly via
# target-type ip, so the Service needs no cloud load balancer of its own.
# Leaving this as the default LoadBalancer is what produced the unconfigured
# Classic ELB in the original setup.
resource "kubectl_manifest" "envoy_proxy" {
  yaml_body = yamlencode({
    apiVersion = "gateway.envoyproxy.io/v1alpha1"
    kind       = "EnvoyProxy"
    metadata = {
      name      = "eg-aws-lb"
      namespace = var.envoy_gw_namespace
    }
    spec = {
      provider = {
        type = "Kubernetes"
        kubernetes = {
          envoyService = {
            type = "ClusterIP"
          }
        }
      }
    }
  })

  depends_on = [helm_release.envoy_gateway]
}

# --- GatewayClass -------------------------------------------------------------
# parametersRef is the supported way to attach an EnvoyProxy (the other being
# Gateway.spec.infrastructure.parametersRef). The original scripts used
# gateway.envoyproxy.io/infra-backend* annotations, which are not a real API —
# nothing read them, so the EnvoyProxy was orphaned.
resource "kubectl_manifest" "gateway_class" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = "eg"
    }
    spec = {
      controllerName = "gateway.envoyproxy.io/gatewayclass-controller"
      parametersRef = {
        group     = "gateway.envoyproxy.io"
        kind      = "EnvoyProxy"
        name      = "eg-aws-lb"
        namespace = var.envoy_gw_namespace
      }
    }
  })

  depends_on = [kubectl_manifest.envoy_proxy]
}

# --- Gateway ------------------------------------------------------------------
resource "kubectl_manifest" "gateway" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = var.gateway_name
      namespace = var.namespace_cloudbees
    }
    spec = {
      gatewayClassName = "eg"
      listeners = [{
        # The listener NAME must stay "https": the CloudBees chart is given
        # Gateway.SectionName=https and binds its HTTPRoute to that name.
        # Protocol is HTTP because the ALB already terminated TLS.
        name     = "https"
        protocol = "HTTP"
        port     = var.gateway_listener_port
        allowedRoutes = {
          namespaces = {
            from = "All"
          }
        }
      }]
    }
  })

  depends_on = [
    kubectl_manifest.gateway_class,
    kubernetes_namespace.cloudbees,
  ]
}

# --- ClientTrafficPolicy: keep encoded slashes ---------------------------------
# Jenkins' reverse-proxy monitor requests a callback URL containing %2F:
#   /cjoc/administrativeMonitor/hudson.diagnosis.ReverseProxySetupMonitor/...
# Envoy's default UnescapeAndRedirect fails these with path_normalization_failed.
# See https://gateway.envoyproxy.io/latest/api/extension_types/#pathsettings
resource "kubectl_manifest" "keep_escaped_slashes" {
  yaml_body = yamlencode({
    apiVersion = "gateway.envoyproxy.io/v1alpha1"
    kind       = "ClientTrafficPolicy"
    metadata = {
      name      = "keep-escaped-slashes"
      namespace = var.namespace_cloudbees
    }
    spec = {
      targetRefs = [{
        group = "gateway.networking.k8s.io"
        kind  = "Gateway"
        name  = var.gateway_name
      }]
      path = {
        escapedSlashesAction = "KeepUnchanged"
      }
    }
  })

  depends_on = [kubectl_manifest.gateway]
}

# --- Stable Service in front of the Envoy pods --------------------------------
# Envoy Gateway names the Service it generates
# "envoy-<gw-namespace>-<gw-name>-<hash>", so it cannot be referenced from an
# Ingress without discovering the name at runtime (which is what forced the
# bash version to shell out to `kubectl get svc -l ...`).
#
# Instead this declares its own Service selecting the Envoy pods by their
# owning-gateway labels. The name is stable, so the Ingress below is a plain
# static resource and the whole stack stays declarative.
resource "kubernetes_service" "envoy_stable" {
  metadata {
    name      = "envoy-${var.gateway_name}-stable"
    namespace = var.envoy_gw_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      "gateway.envoyproxy.io/owning-gateway-name"      = var.gateway_name
      "gateway.envoyproxy.io/owning-gateway-namespace" = var.namespace_cloudbees
    }

    port {
      name = "http"
      port = var.gateway_listener_port
      # Equal to port because gateway_listener_port is unprivileged — Envoy
      # Gateway binds privileged listener ports on a shifted container port.
      target_port = var.gateway_listener_port
      protocol    = "TCP"
    }
  }

  depends_on = [kubectl_manifest.gateway]
}

# --- Ingress: this is what actually provisions the ALB ------------------------
resource "kubernetes_ingress_v1" "cjoc_alb" {
  # Must share a namespace with the Service it targets, not with the Gateway.
  metadata {
    name      = "cjoc-alb"
    namespace = var.envoy_gw_namespace

    annotations = {
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn"  = local.infra.acm_certificate_arn
      "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
      "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"

      "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=${var.alb_idle_timeout_seconds}"

      # Envoy answers "/" with 404 when no HTTPRoute matches it. That 404 still
      # proves the proxy is alive, so it counts as healthy. Narrow this to
      # /cjoc/login once CJOC is up if you want a stricter check.
      "alb.ingress.kubernetes.io/healthcheck-path" = "/"
      "alb.ingress.kubernetes.io/healthcheck-port" = "traffic-port"
      "alb.ingress.kubernetes.io/success-codes"    = "200-404"

      "alb.ingress.kubernetes.io/tags" = join(",", [for k, v in var.tags : "${k}=${v}"])
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = local.infra.cjoc_host_name

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service.envoy_stable.metadata[0].name
              port {
                number = var.gateway_listener_port
              }
            }
          }
        }
      }
    }
  }

  # Mirrors the polling loop in the bash version — blocks until the ALB has a
  # DNS name so the output below is populated on first apply.
  wait_for_load_balancer = true

  depends_on = [
    helm_release.alb_controller,
    kubernetes_service.envoy_stable,
  ]
}
