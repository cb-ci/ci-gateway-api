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

  values = [yamlencode({
    Gateway = {
      Enabled     = true
      Name        = var.gateway_name
      SectionName = "https"
      Namespace   = var.namespace_cloudbees
    }

    OperationsCenter = {
      HostName = local.infra.cjoc_host_name
      # https even though Envoy's listener is plain HTTP — this controls the
      # URLs CJOC generates, and the ALB is what terminates TLS.
      Protocol = "https"
      # Forces CJOC onto the tainted "controllers" pool. A toleration alone
      # only grants permission to land there — nodeSelector is what actually
      # requires it (see controller-statefullset-patch.yaml for the same
      # nodeSelector-over-affinity caveat on dynamically-provisioned
      # Managed Controllers).
      NodeSelector = {
        workload = "controller"
      }
      Tolerations = [{
        key      = "workload"
        operator = "Equal"
        value    = "controller"
        effect   = "NoSchedule"
      }]
    }

    Agents = {
      SeparateNamespace = {
        Enabled = true
        Create  = true
      }
    }

    Persistence = {
      StorageClass = var.storage_class_name
    }

    Common = {
      image = {
        tag = var.cloudbees_image_tag
      }
    }
  })]

  depends_on = [
    kubernetes_namespace.cloudbees,
    kubernetes_storage_class.efs,
    kubectl_manifest.gateway,
  ]
}
