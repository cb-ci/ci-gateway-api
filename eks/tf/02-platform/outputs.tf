output "alb_dns_name" {
  description = "Public DNS name of the ALB. external-dns points cjoc_host_name at this."
  value       = try(kubernetes_ingress_v1.cjoc_alb.status[0].load_balancer[0].ingress[0].hostname, null)
}

output "cjoc_url" {
  description = "Operations Center URL (resolvable once external-dns has published the record)."
  value       = "https://${local.infra.cjoc_host_name}/cjoc/"
}

output "envoy_service_name" {
  description = "Stable Service the ALB targets."
  value       = kubernetes_service.envoy_stable.metadata[0].name
}

output "storage_class" {
  description = "EFS-backed StorageClass used for CloudBees CI persistence."
  value       = kubernetes_storage_class.efs.metadata[0].name
}

output "kubeconfig_command" {
  description = "Write a kubeconfig entry for this cluster."
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${local.cluster}"
}

output "remote_agent_token" {
  description = "Bearer token for the jenkins-agent ServiceAccount — paste into Jenkins as a Secret Text credential for the Kubernetes Cloud config. See ../README-REMOTE-AGENT.md."
  value       = try(kubernetes_secret_v1.remote_agent_token.data["token"], null)
  sensitive   = true
}

output "remote_agent_token_command" {
  description = "Fallback to fetch the token by hand if the output above is null (e.g. right after the first apply, before the token controller populates it)."
  value       = "kubectl get secret jenkins-agent-token -n ${var.remote_agent_namespace} -o jsonpath='{.data.token}' | base64 -d"
}
