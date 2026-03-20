{{- define "ssorelay.labels" -}}
app.kubernetes.io/component: ssorelay
{{ include "cloudbees-core.labels" . }}
{{- end -}}

{{/*
Same as ssorelay.labels but without helm.sh/chart that includes the version changing on every release.
*/}}
{{- define "ssorelay.selector.labels" -}}
app.kubernetes.io/component: ssorelay
{{ include "cloudbees-core.instance-name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- if .Values.Common.labels }}
{{ toYaml .Values.Common.labels }}
{{- end }}
{{- end -}}

{{- define "ssorelay.namespace" -}}
{{ default .Release.Namespace .Values.Master.OperationsCenterNamespace }}
{{- end -}}

{{/*
Expected SSO Relay Hostname.
*/}}
{{- define "ssorelay.hostnamewithoutport" -}}
{{- if (include "cloudbees-core.use-subdomain" .) -}}
{{ .Values.SubdomainServicePrefix }}sso-relay.
{{- end -}}
{{ .Values.OperationsCenter.HostName }}
{{- end -}}

{{/*
Expected SSO Relay Path.
TODO perhaps inline this, since it is a constant now anyway
*/}}
{{- define "ssorelay.contextpath" -}}
/sso-relay/
{{- end -}}

{{/*
Expected SSO Relay URL. Always ends with a trailing slash.
*/}}
{{- define "ssorelay.url" -}}
{{- include "oc.protocol" . -}}://{{ include "ssorelay.hostnamewithoutport" . }}{{ include "ssorelay.contextpath" . }}
{{- end -}}

{{/*
Expected SSO Relay URL. Always ends with a trailing slash.
*/}}
{{- define "ssorelay.configmapname" -}}
cloudbees-sso-relay-trusted-controllers
{{- end -}}

{{- define "ssorelay.ingress.annotations" -}}
{{ include "ingress.annotations" . }}
{{- if eq .Values.OperationsCenter.Platform "eks" }}
alb.ingress.kubernetes.io/healthcheck-path: /health/live
{{- end }}
{{- end }}
