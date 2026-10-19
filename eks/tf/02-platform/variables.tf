variable "namespace_cloudbees" {
  description = "Namespace for CloudBees CI (Operations Center + controllers)."
  type        = string
  default     = "cloudbees-core"
}

variable "envoy_gw_namespace" {
  description = "Namespace for the Envoy Gateway controller, its proxy pods, and the ALB Ingress."
  type        = string
  default     = "envoy-gateway-system"
}

variable "namespace_external_dns" {
  description = <<-EOT
    Namespace for external-dns. Must match the EKS Pod Identity association
    created in 01-infra (kube-system) — changing this alone will silently
    leave external-dns without Route53 credentials.
  EOT
  type        = string
  default     = "kube-system"
}

variable "external_dns_service_account" {
  description = "external-dns ServiceAccount name. Must match the Pod Identity association in 01-infra."
  type        = string
  default     = "external-dns"
}

variable "gateway_name" {
  description = "Name of the Gateway API Gateway resource. 04's Helm values bind CloudBees HTTPRoutes to it."
  type        = string
  default     = "cloudbees-gateway"
}

variable "gateway_listener_port" {
  description = <<-EOT
    Port the Envoy listener binds. Deliberately >= 1024: Envoy Gateway shifts
    privileged listener ports to a different container port internally, so
    using 8443 keeps the Service targetPort predictable for the stable Service
    the ALB targets. TLS terminates at the ALB, so this is cluster-internal
    and never appears in a user-facing URL.
  EOT
  type        = number
  default     = 8443

  validation {
    condition     = var.gateway_listener_port >= 1024
    error_message = "Use an unprivileged port so the Envoy container port matches the listener port."
  }
}

variable "envoy_gateway_version" {
  description = "Envoy Gateway Helm chart version. Empty string installs the latest published chart."
  type        = string
  default     = ""
}

variable "lbc_chart_version" {
  description = "aws-load-balancer-controller Helm chart version. Verify with: helm search repo eks/aws-load-balancer-controller --versions"
  type        = string
  default     = "1.14.0"
}

variable "external_dns_chart_version" {
  description = "external-dns Helm chart version. Empty string installs the latest published chart."
  type        = string
  default     = ""
}

variable "cluster_autoscaler_chart_version" {
  description = "cluster-autoscaler Helm chart version. Verify with: helm search repo autoscaler/cluster-autoscaler --versions"
  type        = string
  default     = "9.46.6"
}

variable "cluster_autoscaler_image_tag" {
  description = <<-EOT
    cluster-autoscaler image tag override. Empty string derives "v<cluster_version>.0"
    from 01-infra's cluster_version output — cluster-autoscaler releases track EKS
    minor versions 1:1, and a mismatched image is a common source of silent
    scaling failures. Override if that derived tag doesn't exist on
    registry.k8s.io/autoscaling/cluster-autoscaler.
  EOT
  type        = string
  default     = ""
}

variable "cloudbees_image_tag" {
  description = <<-EOT
    Common.image.tag for the CloudBees CI chart. Carried over as "latest" from
    05-inatallCloudBees.sh to preserve existing behaviour, but pinning an
    explicit version is strongly recommended: "latest" makes every pod restart
    a potential unplanned upgrade and makes rollbacks non-deterministic.
  EOT
  type        = string
  default     = "latest"
}

variable "storage_class_name" {
  description = "Name of the EFS-backed StorageClass used for CloudBees CI persistence."
  type        = string
  default     = "efs-sc"
}

variable "alb_idle_timeout_seconds" {
  description = <<-EOT
    ALB idle timeout. The AWS default of 60s severs Jenkins long-polling and
    SSE build-log streams mid-request; 4000 is the ALB maximum.
  EOT
  type        = number
  default     = 4000
}

variable "remote_agent_namespace" {
  description = <<-EOT
    Namespace the jenkins-agent ServiceAccount/Role/RoleBinding/token Secret
    are created in, for a Jenkins "Kubernetes Cloud" configured on a
    controller running outside this cluster (03-ec2-controller). Must match
    the namespace the CloudBees CI chart's Agents.SeparateNamespace feature
    actually created — confirm with `kubectl get ns` rather than assuming.
  EOT
  type        = string
  default     = "cloudbees-core-builds"
}

variable "tags" {
  description = "Tags propagated to AWS resources created by in-cluster controllers (the ALB)."
  type        = map(string)
  default = {
    cb-user        = "acaternberg"
    cb-owner       = "professional-services"
    cb-environment = "demo"
  }
}
