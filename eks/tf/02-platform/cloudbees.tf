# =============================================================================
# CLOUDBEES CI — replaces 05-inatallCloudBees.sh
# =============================================================================
# The chart renders the HTTPRoute that binds to the Gateway's "https" listener,
# which is why the listener name must not change.

resource "helm_release" "cloudbees_ci" {
  name       = "cloudbees-core-envoy"
  repository = "https://charts.cloudbees.com/public/cloudbees"
  chart      = "cloudbees-core"
  namespace  = var.namespace_cloudbees

  # CJOC is a StatefulSet restoring JENKINS_HOME from EFS; give it room.
  timeout = 900

  # Static values live in cloudbees-values.yaml.tftpl; only the variable parts
  # are injected here.
  values = [templatefile("${path.module}/cloudbees-values.yaml.tftpl", {
    gateway_name       = var.gateway_name
    namespace          = var.namespace_cloudbees
    cjoc_host_name     = local.infra.cjoc_host_name
    storage_class_name = var.storage_class_name
    image_tag          = var.cloudbees_image_tag
  })]

  depends_on = [
    kubernetes_namespace.cloudbees,
    kubernetes_storage_class.efs,
    kubectl_manifest.gateway,
  ]
}
