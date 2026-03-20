{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}

{{- define "cloudbees-core.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- template "validate.gateway" . -}}
{{- end -}}

{{/*
Full name of the release
*/}}
{{- define "cloudbees-core.fullname" -}}
{{ printf "%s-%s" .Release.Name .Release.Namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cloudbees-core.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mm.longname" -}}
CloudBees CI - Managed Controller - {{ include "mm.longname-suffix" .}}
{{- end -}}

{{- define "oc.image" -}}
{{- if dig "Image" "dockerImage" "" .Values.OperationsCenter -}}
{{ .Values.OperationsCenter.Image.dockerImage }}
{{- else -}}
{{ .Values.OperationsCenter.image.registry | default .Values.Common.image.registry }}/{{ .Values.OperationsCenter.image.repository }}{{- with .Values.OperationsCenter.image.tag | default .Values.Common.image.tag -}}{{- if eq (substr 0 7 .) "sha256:" -}}@{{.}}{{- else -}}:{{.}}{{- end -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mm.image" -}}
{{- if dig "Image" "dockerImage" "" .Values.Master -}}
{{ .Values.Master.Image.dockerImage }}
{{- else -}}
{{ .Values.Master.image.registry | default .Values.Common.image.registry }}/{{ .Values.Master.image.repository }}{{- with .Values.Master.image.tag | default .Values.Common.image.tag -}}{{- if eq (substr 0 7 .) "sha256:" -}}@{{.}}{{- else -}}:{{.}}{{- end -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "agents.image" -}}
{{- if dig "Image" "dockerImage" "" .Values.Agents -}}
{{ .Values.Agents.Image.dockerImage }}
{{- else -}}
{{ .Values.Agents.image.registry | default .Values.Common.image.registry}}/{{ .Values.Agents.image.repository }}{{- with .Values.Agents.image.tag | default .Values.Common.image.tag -}}{{- if eq (substr 0 7 .) "sha256:" -}}@{{.}}{{- else -}}:{{.}}{{- end -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "hibernation.image" -}}
{{- if dig "Image" "dockerImage" "" .Values.Hibernation -}}
{{ .Values.Hibernation.Image.dockerImage }}
{{- else -}}
{{ .Values.Hibernation.image.registry | default .Values.Common.image.registry}}/{{ .Values.Hibernation.image.repository }}{{- with .Values.Hibernation.image.tag | default .Values.Common.image.tag -}}{{- if eq (substr 0 7 .) "sha256:" -}}@{{.}}{{- else -}}:{{.}}{{- end -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "PluggableStorageService.image" -}}
{{ .Values.PluggableStorageService.image.registry | default .Values.Common.image.registry}}/{{ .Values.PluggableStorageService.image.repository }}:{{- .Values.PluggableStorageService.image.tag | default .Values.Common.image.tag -}}
{{- end -}}

{{- define "oc.imagePullPolicy" -}}
{{- if dig "Image" "dockerPullPolicy" "" .Values.Master -}}
{{ .Values.OperationsCenter.Image.dockerPullPolicy }}
{{- else -}}
{{ .Values.OperationsCenter.image.pullPolicy | default .Values.Common.image.pullPolicy | default "" }}
{{- end -}}
{{- end -}}

{{- define "mm.imagePullPolicy" -}}
{{ .Values.Master.image.pullPolicy | default .Values.Common.image.pullPolicy | default "" }}
{{- end -}}

{{- define "hibernation.imagePullPolicy" -}}
{{- if dig "Image" "dockerPullPolicy" "" .Values.Hibernation -}}
{{ .Values.Hibernation.Image.dockerPullPolicy }}
{{- else -}}
{{ .Values.Hibernation.image.pullPolicy | default .Values.Common.image.pullPolicy | default "" }}
{{- end -}}

{{- end -}}

{{- define "PluggableStorageService.imagePullPolicy" -}}
{{ .Values.PluggableStorageService.image.pullPolicy | default .Values.Common.image.pullPolicy | default "" }}
{{- end -}}

{{/*
If the image is by digest, we assume it is a development image.
If the image is a tag, we use the tag as is.
*/}}
{{- define "mm.longname-suffix" -}}
{{- with include "mm.image" . -}}
{{- if contains "@sha256" . -}}
DEVELOPMENT
{{- else -}}
{{ substr ((splitn ":" 2 .)._0 | len | add1 | int ) (len .) . }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return instance and name labels.
*/}}
{{- define "cloudbees-core.instance-name" -}}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/name: {{ include "cloudbees-core.name" . | quote }}
{{- end -}}

{{- define "cloudbees-core.cli" -}}
{{- if include "cloudbees-core.is-openshift" . -}}
oc
{{- else -}}
kubectl
{{- end -}}
{{- end -}}

{{- define "cloudbees-core.needs-routes" -}}
{{- if and (not .Values.Gateway) (or (include "cloudbees-core.is-openshift" . ) (.Values.OperationsCenter.Route.tls.Enable)) -}}
true
{{- end -}}
{{- end -}}

{{- define "cloudbees-core.needs-httproute" -}}
{{- if .Values.Gateway -}}
true
{{- end -}}
{{- end -}}

{{- define "cloudbees-core.needs-ingress" -}}
{{- if and (not (include "cloudbees-core.needs-routes" .)) (not (include "cloudbees-core.needs-httproute" .)) -}}
true
{{- end -}}
{{- end -}}

{{- define "cloudbees-core.is-openshift" -}}
{{- if or (has .Values.OperationsCenter.Platform (list "openshift4")) (.Capabilities.APIVersions.Has "ingress.operator.openshift.io/v1") -}}
true
{{- end -}}
{{- end -}}

{{- define "cloudbees-core.use-subdomain" -}}
{{- if and (eq (typeOf .Values.Subdomain) "bool") (eq .Values.Subdomain true) -}}
true
{{- end -}}
{{- end -}}

{{/*
Return labels, including instance and name.
*/}}
{{- define "cloudbees-core.labels" -}}
{{ include "cloudbees-core.instance-name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
helm.sh/chart: {{ include "cloudbees-core.chart" . | quote }}
{{- if .Values.Common.labels }}
{{ toYaml .Values.Common.labels }}
{{- end }}
{{- end -}}

{{- define "oc.protocol" -}}
{{- if or (.Values.OperationsCenter.Ingress.tls.Enable) (.Values.OperationsCenter.Route.tls.Enable) -}}https{{- else -}}{{ .Values.OperationsCenter.Protocol }}{{- end -}}
{{- end -}}

{{/*
Sanitize Operations Center context path to never have a trailing slash
*/}}
{{- define "oc.contextpath" -}}
{{- if not (empty .Values.OperationsCenter.ContextPath) -}}
{{- trimSuffix "/" .Values.OperationsCenter.ContextPath -}}
{{- else -}}
{{- if not (include "cloudbees-core.use-subdomain" .) -}}
/
{{- include "oc.name" . }}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "oc.ingresspath" -}}
{{- if hasPrefix "/" (include "oc.contextpath" .) -}}
{{- include "oc.contextpath" . -}}
{{- else -}}
/{{- include "oc.contextpath" . -}}
{{- end -}}
{{- end -}}

{{- define "oc.name" -}}
{{ .Values.OperationsCenter.Name }}
{{- end -}}

{{- define "oc.defaultPort" -}}
{{- if eq (include "oc.protocol" .) "https" -}}443{{- else if eq (include "oc.protocol" .) "http" -}}80{{- end -}}
{{- end -}}

{{- define "oc.port" -}}
{{- .Values.OperationsCenter.Port | default (include "oc.defaultPort" .) -}}
{{- end -}}

{{- define "oc.optionalPort" -}}
{{- if ne (include "oc.port" .) (include "oc.defaultPort" .) -}}
:{{ include "oc.port" . }}
{{- end -}}
{{- end -}}

{{/*
Expected Operations Center Hostname. Include port if not 80/443.
*/}}
{{- define "oc.hostname" -}}
{{- include "oc.hostnamewithoutport" . -}}{{- include "oc.optionalPort" . -}}
{{- end -}}

{{/*
Expected Operations Center Hostname. Include port if not 80/443.
*/}}
{{- define "oc.hostnamewithoutport" -}}
{{- if (include "cloudbees-core.use-subdomain" .)  -}}
{{- include "oc.name" . -}}.
{{- end -}}
{{- if kindIs "string" .Values.OperationsCenter.HostName -}}
{{ .Values.OperationsCenter.HostName }}
{{- end -}}
{{- end -}}

{{/*
Expected Hibernation Monitor Hostname
*/}}
{{- define "hibernation.hostnamewithoutport" -}}
{{- if (include "cloudbees-core.use-subdomain" .) -}}
hibernation-{{ .Release.Namespace }}.
{{- end -}}
{{ .Values.OperationsCenter.HostName }}
{{- end -}}

{{/*
Expected Operations Center URL. Always ends with a trailing slash.
*/}}
{{- define "oc.url" -}}
{{- include "oc.protocol" . -}}://{{ include "oc.hostname" . }}{{ include "oc.contextpath" . }}/
{{- end -}}

{{- define "ingress.annotations" -}}
{{ toYaml .Values.OperationsCenter.Ingress.Annotations }}
{{- if eq .Values.OperationsCenter.Platform "eks" }}
  {{- if eq (include "oc.protocol" .) "https" }}
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}, {"HTTPS":443}]'
alb.ingress.kubernetes.io/ssl-redirect: '443'
  {{- end }}
  {{- if not (eq (include "oc.contextpath" .) "") }}
alb.ingress.kubernetes.io/actions.root-redirect: '{"Type": "redirect", "RedirectConfig": { "Path":{{ include "ingress.root-redirect" . | quote }}, "StatusCode": "HTTP_301"}}'
  {{- end }}
alb.ingress.kubernetes.io/group.name: {{ include "cloudbees-core.fullname" .}}
alb.ingress.kubernetes.io/target-type: ip
{{- end }}
{{- if not (include "cloudbees-core.is-openshift" .) }}
nginx.ingress.kubernetes.io/ssl-redirect: "{{ .Values.OperationsCenter.Ingress.tls.Enable }}"
{{- end }}
{{- end }}

{{- define "cjoc.ingress.annotations" -}}
{{ include "ingress.annotations" . }}
{{- if eq .Values.OperationsCenter.Platform "eks" }}
alb.ingress.kubernetes.io/healthcheck-path: {{ include "oc.contextpath" . }}/health/
{{- end }}
{{- if not (include "cloudbees-core.is-openshift" .) }}
{{- if not (eq (include "oc.contextpath" .) "") }}
nginx.ingress.kubernetes.io/app-root: {{ include "ingress.root-redirect" . | quote }}
{{- end }}
# "413 Request Entity Too Large" uploading plugins, increase client_max_body_size
nginx.ingress.kubernetes.io/proxy-body-size: 50m
nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
{{- end }}
{{- end }}

{{- define "hibernationMonitor.ingress.annotations" -}}
{{ include "ingress.annotations" . }}
{{- if eq .Values.OperationsCenter.Platform "eks" }}
alb.ingress.kubernetes.io/healthcheck-path: /health/live
{{- end }}
{{- end }}

{{- define "ingress.root-redirect" -}}
{{ include "oc.contextpath" . }}/
{{- end }}

{{- define "ingress.redirect-rules" -}}
{{- if eq .Values.OperationsCenter.Platform "eks" }}
{{- if not (eq (include "oc.contextpath" .) "") }}
- path: /
  pathType: ImplementationSpecific
  backend:
    service:
      name: root-redirect
      port:
        name: use-annotation
{{- end -}}
{{- end -}}
{{- end }}

{{/*
If rbac.installCluster is defined, honor it.
Otherwise, default to true, except on multi-namespace where we default false
*/}}
{{- define "rbac.install-cluster" -}}
{{- if eq (typeOf .Values.rbac.installCluster) "bool" -}}
{{- if eq .Values.rbac.installCluster true -}}
true
{{- else if eq .Values.rbac.installCluster false -}}
false
{{- end -}}
{{- else if .Values.OperationsCenter.Enabled -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
RBAC Group subject renderer for RoleBinding/ClusterRoleBinding.
Adds the Group only if .Values.rbac.groupName is a non-empty string.
*/}}
{{- define "rbac.group-subject" -}}
{{- $group := (default "" .Values.rbac.groupName) | trim -}}
{{- if ne $group "" }}
- kind: Group
  apiGroup: rbac.authorization.k8s.io
  name: {{ $group | quote }}
{{- end -}}
{{- end }}

{{- define "validate.operationscenter" -}}
{{- if and (.Values.OperationsCenter.Enabled) (.Values.Master.OperationsCenterNamespace) -}}
{{ fail "Can't use both OperationsCenter.Enabled=true and Master.OperationsCenterNamespace" }}
{{- end -}}
{{- end -}}

{{/* Advanced securityContext - START */}}
{{- define "oc.simpleSecurityContextEnabled" -}}
{{- if or (.Values.OperationsCenter.RunAsUser) (.Values.OperationsCenter.RunAsGroup) (.Values.OperationsCenter.FsGroup) -}}
true
{{- end -}}
{{- end -}}

{{- define "oc.advancedSecurityContextEnabled" -}}
{{- if or (.Values.OperationsCenter.PodSecurityContext) (.Values.OperationsCenter.ContainerSecurityContext) -}}
true
{{- end -}}
{{- end -}}

{{- define "validate.securityContext" -}}
{{- if and (include "oc.simpleSecurityContextEnabled" .) (include "oc.advancedSecurityContextEnabled" .) -}}
{{ fail "Can't use both OperationsCenter.(PodSecurityContext|ContainerSecurityContext) and .OperationsCenter.(FsGroup|RunAsUser|RunASGroup)" }}
{{- end -}}
{{- end -}}

{{/*
 if .OperationsCenter.PodSecurityContext set, then take that, otherwise
 * fsGroup defaults to 1000 (default image UID)
 * on OpenShift it defaults to unset
 * if runAsUser is 0 it defaults to unset
*/}}
{{- define "oc.podSecurityContext" -}}
{{- if and (not (eq (toString .Values.OperationsCenter.ContainerSecurityContext.runAsUser) "0")) (not (include "cloudbees-core.is-openshift" .)) -}}
fsGroup: 1000
{{- else -}}
fsGroup: null
{{- end -}}
{{- end -}}
{{/* Advanced securityContext - END */}}

{{/* Simple securityContext - START */}}
{{/*
 fsGroup defaults to 1000 (default image UID)
 * on OpenShift it defaults to unset
 * if runAsUser is 0 it defaults to unset
*/}}
{{- define "oc.fsGroup" -}}
{{- default (include "oc.defaultFsGroup" .) .Values.OperationsCenter.FsGroup -}}
{{- end -}}

{{- define "oc.defaultFsGroup" -}}
{{- if and (not (eq (toString .Values.OperationsCenter.RunAsUser) "0")) (not (include "cloudbees-core.is-openshift" .)) -}}
1000
{{- end -}}
{{- end -}}
{{/* Simple securityContext - END */}}

{{/*
Pod selectors for network monitor spec
*/}}

{{- define "operationsCenter.podSelector" -}}
podSelector:
  matchLabels:
    app.kubernetes.io/instance: {{ .Release.Name | quote }}
    app.kubernetes.io/component: cjoc
{{- end -}}

{{- define "agent.podSelector" -}}
podSelector:
  matchLabels:
    jenkins: slave
{{- end -}}

{{- define "controller.namespaceSelector" -}}
namespaceSelector:
  matchLabels:
    cloudbees.com/role: controller
{{- end -}}

{{- define "controller.namespaceSelectors" -}}
{{ include "master.podSelector" . | indent 2 | trim | printf "- %s" }}
{{ include "controller.namespaceSelector" . | indent 3 | trim | printf "  %s" }}
{{- end -}}

{{- define "master.podSelector" -}}
podSelector:
  matchLabels:
    com.cloudbees.cje.type: master
{{- end -}}

{{- define "hibernationMonitor.podSelector" -}}
podSelector:
  matchLabels:
    app: managed-master-hibernation-monitor
    app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{- define "PluggableStorageService.podSelector" -}}
podSelector:
  matchLabels:
    app: pluggable-storage-service
    app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{/*
Plural versions for usage in network policy ingress rules
*/}}

{{- define "agent.podSelectors" -}}
{{ include "agent.podSelector" . | indent 2 | trim | printf "- %s"}}
{{- if .Values.Agents.SeparateNamespace.Enabled }}
  namespaceSelector:
    matchLabels:
      cloudbees.com/role: agents
{{- end -}}
{{- end -}}

{{- define "operationsCenter.podSelectors" -}}
{{ include "operationsCenter.podSelector" . | indent 2 | trim | printf "- %s"}}
{{- end -}}

{{- define "master.podSelectors" -}}
{{ include "master.podSelector" . | indent 2 | trim | printf "- %s"}}
{{- end -}}

{{- define "hibernationMonitor.podSelectors" -}}
{{- if .Values.Hibernation.Enabled }}
{{ include "hibernationMonitor.podSelector" . | indent 2 | trim | printf "- %s"}}
{{- else }}
[]
{{- end -}}
{{- end -}}

{{- define "ingress.podSelectors" -}}
{{- if .Values.NetworkPolicy.ingressControllerSelector }}
{{ toYaml .Values.NetworkPolicy.ingressControllerSelector }}
{{- else if and .Values.Gateway ((.Values.OperationsCenter).Gateway) ((.Values.OperationsCenter).Gateway).Namespace }}
  {{/* Gateway API - allow traffic from Gateway namespace */}}
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: {{ .Values.OperationsCenter.Gateway.Namespace }}
{{- else if include "cloudbees-core.is-openshift" . -}}
- namespaceSelector:
    matchLabels:
      network.openshift.io/policy-group: ingress
{{- else if eq .Values.OperationsCenter.Platform "eks" }}
{{/* ALB retains source ip so everything must be allowed in this context */}}
- ipBlock:
    cidr: 0.0.0.0/0
{{- else }}
[]
{{- end -}}
{{- end -}}

{{- define "persistence.storageclass" -}}
{{/* Separate if blocks because go template doesn't evaluate 'and' clause lazily */}}
{{- if typeIs "string" .Values.Persistence.StorageClass -}}
{{- if ne "-" .Values.Persistence.StorageClass -}}
{{ .Values.Persistence.StorageClass}}
{{- end -}}
{{- else if (include "gke.storageclass.name" .) -}}
{{ include "gke.storageclass.name" . }}
{{- else if (include "aks.storageclass.name" .) -}}
{{ include "aks.storageclass.name" . }}
{{- end -}}
{{- end -}}

{{- define "gke.storageclass.name" -}}
{{- if eq "gke" .Values.OperationsCenter.Platform -}}
ssd-{{ .Release.Name }}-{{ .Release.Namespace }}
{{- end -}}
{{- end -}}

{{/*
Always use managed-premium storage class when running on AKS
*/}}
{{- define "aks.storageclass.name" -}}
{{- if eq "aks" .Values.OperationsCenter.Platform -}}
managed-premium
{{- end -}}
{{- end -}}

{{- define "openshift.tls" -}}
{{- if .Values.OperationsCenter.Route.tls.Enable -}}
tls:
  insecureEdgeTerminationPolicy: {{ .Values.OperationsCenter.Route.tls.InsecureEdgeTerminationPolicy }}
  termination: {{ .Values.OperationsCenter.Route.tls.Termination }}
{{- if .Values.OperationsCenter.Route.tls.CACertificate }}
  caCertificate: |-
{{ .Values.OperationsCenter.Route.tls.CACertificate | indent 4 }}
{{- end }}
{{- if .Values.OperationsCenter.Route.tls.Certificate }}
  certificate: |-
{{ .Values.OperationsCenter.Route.tls.Certificate | indent 4 }}
{{- end }}
{{- if .Values.OperationsCenter.Route.tls.Key }}
  key: |-
{{ .Values.OperationsCenter.Route.tls.Key | indent 4 }}
{{- end }}
{{- if .Values.OperationsCenter.Route.tls.DestinationCACertificate }}
  destinationCACertificate: |-
{{ .Values.OperationsCenter.Route.tls.DestinationCACertificate | indent 4}}
{{- end }}
{{- end }}
{{- end }}

{{- define "agents.namespace" -}}
{{- if .Values.Agents.SeparateNamespace.Enabled -}}
{{ default (printf "%s-%s" .Release.Namespace "builds") .Values.Agents.SeparateNamespace.Name }}
{{- else -}}
{{ .Release.Namespace }}
{{- end -}}
{{- end -}}

{{- define "hibernation.routenonnamespacedurls" -}}
{{- if and (eq (typeOf .Values.OperationsCenter.Enabled) "bool") (eq .Values.OperationsCenter.Enabled false) -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "validate.gateway" -}}
{{- if .Values.Gateway -}}
  {{- if not ((.Values.OperationsCenter.Gateway).Name) -}}
    {{- fail "ERROR: when Gateway mode Enabled OperationsCenter.Gateway.Name is mandatory" -}}
  {{- end -}}
  {{- if not (.Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1") -}}
    {{- fail "ERROR: Gateway API CRDs not found." -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/* Separate service accounts are enabled by default, unless rbac.masterSeparateServiceAccount is set to false */}}
{{/* Do not use it. Setting it to false will make various product features to not work */}}
{{- define "rbac.masterSeparateServiceAccount" -}}
{{- if (eq .Values.rbac.masterSeparateServiceAccount false) -}}
{{- if eq (include "isAnyM2MAuthServiceEnabled" .) "true" -}}
{{ fail "ERROR: CascBundleService.enabled and PluggableStorageService.enabled require rbac.masterSeparateServiceAccount to be true." }}
{{- else -}}
false
{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/* Indicates whether any services that use Kubernetes service accounts for machine-to-machine authentication are enabled */}}
{{- define "isAnyM2MAuthServiceEnabled" -}}
{{ or .Values.CascBundleService.enabled .Values.PluggableStorageService.enabled }}
{{- end}}

{{/* Indicates whether tokenreview RBAC should be created. When Master.tokenReviewEnabled is explicitly set (non-null), use that value. Otherwise, infer from isAnyM2MAuthServiceEnabled. */}}
{{- define "isTokenReviewEnabled" -}}
{{- if eq (typeOf .Values.Master.tokenReviewEnabled) "bool" -}}
{{ .Values.Master.tokenReviewEnabled }}
{{- else -}}
{{ include "isAnyM2MAuthServiceEnabled" . }}
{{- end -}}
{{- end -}}
