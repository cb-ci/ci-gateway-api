# =============================================================================
# REMOTE AGENT SERVICE ACCOUNT — replaces 08-createServiceAccountforRemoteAgents.sh
# =============================================================================
# RBAC identity for a Jenkins "Kubernetes Cloud" configured on a controller
# that runs OUTSIDE this cluster (the EC2 Client Controller from
# 03-ec2-controller) — it authenticates with a bearer token, not IRSA/Pod
# Identity, since it has no AWS-native way to assume a role scoped to this
# cluster's API server. See ../README.md and ../../README-REMOTE-AGENT.md for
# how this gets wired into Jenkins.
#
# The target namespace is NOT created here: it's whatever the CloudBees CI
# chart's Agents.SeparateNamespace feature actually created (05-inatallCloudBees.sh
# / cloudbees.tf). Creating it here too would fight the chart for ownership.
resource "kubernetes_service_account_v1" "remote_agent" {
  metadata {
    name      = "jenkins-agent"
    namespace = var.remote_agent_namespace
  }

  depends_on = [helm_release.cloudbees_ci]
}

resource "kubernetes_role_v1" "remote_agent" {
  metadata {
    name      = "jenkins-agent-role"
    namespace = var.remote_agent_namespace
  }

  # Mirrors the single `kubectl create role` call: one verb set applied to
  # every listed resource, not per-resource rules.
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "pods/exec", "events", "persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "create", "delete", "update", "patch"]
  }

  # The namespace comes from the CloudBees chart, so wait for it. The service
  # account already does; without this the Role raced the chart and failed
  # with `namespaces "<name>" not found`.
  depends_on = [helm_release.cloudbees_ci]
}

resource "kubernetes_role_binding_v1" "remote_agent" {
  metadata {
    name      = "jenkins-agent-binding"
    namespace = var.remote_agent_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.remote_agent.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.remote_agent.metadata[0].name
    namespace = var.remote_agent_namespace
  }
}

# A plain `kubectl create token` expires (bound by the API server's
# max-token-expiration) and Jenkins won't auto-refresh a pasted Secret Text
# credential. This legacy-style annotated Secret gets a token that does not
# expire on its own — same trade-off the eksctl script makes.
resource "kubernetes_secret_v1" "remote_agent_token" {
  metadata {
    name      = "jenkins-agent-token"
    namespace = var.remote_agent_namespace

    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.remote_agent.metadata[0].name
    }
  }

  type = "kubernetes.io/service-account-token"

  # The token controller populates data.token asynchronously after the Secret
  # is created; without this, the same apply that creates the Secret could
  # finish before the token exists.
  wait_for_service_account_token = true

  depends_on = [kubernetes_service_account_v1.remote_agent]
}
