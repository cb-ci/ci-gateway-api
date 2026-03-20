{{- define "cascBundleService.globalName" -}}
casc-bundle-service
{{- end -}}

{{/*Sets the right image for the CasC bundle service*/}}
{{- define "cascBundleService.image" -}}
{{- if dig "image" "dockerImage" "" .Values.CascBundleService -}}
{{ .Values.CascBundleService.image.dockerImage }}
{{- else -}}
{{ .Values.CascBundleService.image.registry | default .Values.Common.image.registry }}/{{ .Values.CascBundleService.image.repository }}{{- with .Values.CascBundleService.image.tag | default .Values.Common.image.tag -}}{{- if eq (substr 0 7 .) "sha256:" -}}@{{.}}{{- else -}}:{{.}}{{- end -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "cascBundleService.resources" -}}
requests:
  memory: {{ .Values.CascBundleService.resources.requests.memory }}
  cpu: {{ .Values.CascBundleService.resources.requests.cpu }}
limits:
  memory: {{ .Values.CascBundleService.resources.limits.memory }}
  {{- if ne (.Values.CascBundleService.resources.limits.cpu | toString) "0" }}
  cpu: {{ .Values.CascBundleService.resources.limits.cpu }}
  {{- end }}
{{- end -}}

{{- define "cascBundleService.containerPort" -}}
8080
{{- end -}}

{{- define "cascBundleService.serviceAccount" -}}
{{ required "serviceAccount is required" .Values.CascBundleService.serviceAccountName }}
{{- end -}}

{{- define "cascBundleService.serviceName" -}}
{{- include "cascBundleService.globalName" . -}}
{{- end -}}

{{/*
Expected Operations Center Hostname. Include port if not 80/443.
*/}}
{{- define "cascBundleService.hostnamewithoutport" -}}
{{- if (include "cloudbees-core.use-subdomain" .) -}}
{{ .Values.SubdomainServicePrefix }}casc-bundle-service-{{ .Release.Namespace }}.
{{- end -}}
{{ .Values.OperationsCenter.HostName }}
{{- end -}}

{{- define "cascBundleService.ingress.annotations" -}}
{{ include "ingress.annotations" . }}
{{- if eq .Values.OperationsCenter.Platform "eks" }}
alb.ingress.kubernetes.io/healthcheck-path: /health/live
{{- end }}
{{- end }}