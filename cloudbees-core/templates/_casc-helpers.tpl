{{/* vim: set filetype=mustache: */}}

{{/*
Sets the right image for the CasC bundle retriever
*/}}
{{- define "cloudbees-core.casc.retriever.image" -}}
{{ .Values.OperationsCenter.CasC.Retriever.image.registry | default .Values.Common.image.registry }}/{{ .Values.OperationsCenter.CasC.Retriever.image.repository }}{{- with .Values.OperationsCenter.CasC.Retriever.image.tag -}}{{- if eq (substr 0 7 .) "sha256:" -}}@{{.}}{{- else -}}:{{.}}{{- end -}}{{- end -}}
{{- end -}}

{{/*
sets image pull policy for casc bundle retriever
*/}}
{{- define "cloudbees-core.casc.retriever.imagePullPolicy" -}}
{{ .Values.OperationsCenter.CasC.Retriever.image.pullPolicy | default .Values.Common.image.pullPolicy | default "" }}
{{- end -}}

{{- define "oc.casc_config_map_mount_point" -}}
/var/jenkins_config/oc-casc-bundle
{{- end -}}

{{- define "oc.casc_retriever_bundle_mount_point" -}}
/var/jenkins_config
{{- end -}}

{{- define "oc.casc_retriever_ssh_config_home" -}}
/home/{{- include "oc.casc_retriever_user" . -}}/.ssh
{{- end -}}

{{- define "oc.casc_retriever_user" -}}
retriever
{{- end -}}

{{- define "cloudbees-core.casc.volumeMount" -}}
{{/* If using the retriever we mount the writable shared disk, if not the read only config map */}}
{{- if not .Values.OperationsCenter.CasC.Retriever.Enabled }}
  mountPath: {{ include "oc.casc_config_map_mount_point" . }}
  readOnly: true
{{- else }}
  mountPath: {{ include "oc.casc_retriever_bundle_mount_point" . }}
  readOnly: false
{{- end }}
{{- end -}}

{{/*
Template to define image and imagePullpolicy for init container and sidecar
*/}}
{{- define "oc.casc_retriever.common.image" -}}
image: {{ include "cloudbees-core.casc.retriever.image" . }}
{{- if (include "cloudbees-core.casc.retriever.imagePullPolicy" .) }}
imagePullPolicy: {{ include "cloudbees-core.casc.retriever.imagePullPolicy" . }}
{{- end }}
{{- end -}}

{{/*
Template to host common environment variables for both init container and sidecar
*/}}
{{- define "oc.casc_retriever.common.envVars" -}}
{{- $scmRepo := .Values.OperationsCenter.CasC.Retriever.scmRepo | required "OperationsCenter.CasC.Retriever.scmRepo is mandatory" }}
{{- $scmBranch := .Values.OperationsCenter.CasC.Retriever.scmBranch | required "OperationsCenter.CasC.Retriever.scmBranch is mandatory" }}
{{- $secretName := "casc-retriever-secrets" }}
{{- $secret := .Values.OperationsCenter.CasC.Retriever.secrets }}
{{- if .Values.OperationsCenter.CasC.Retriever.secrets }}
  {{- $secretName = .Values.OperationsCenter.CasC.Retriever.secrets.secretName | default "casc-retriever-secrets" }}
{{- end }}
{{/*
JAVA_OPTS_APPEND is picked up by the jboss base image scripts and appended to the java command line
*/}}
- name: JAVA_OPTS_APPEND
  value: {{ .Values.OperationsCenter.CasC.Retriever.extraJvmArgs }}
- name: casc_retriever_scm_repo
  value: {{ $scmRepo }}
- name: casc_retriever_scm_branch
  value: {{ $scmBranch }}
{{- if .Values.OperationsCenter.CasC.Retriever.scmBundlePath }}
- name: casc_retriever_scm_bundle_path
  value: {{ .Values.OperationsCenter.CasC.Retriever.scmBundlePath }}
{{- end }}
- name: casc_retriever_oc_bundle_location
  value: {{ include "oc.casc_retriever_bundle_mount_point" . }}/oc-casc-bundle
{{- if .Values.OperationsCenter.CasC.Retriever.ocBundleAutomaticVersion }}
- name: casc_retriever_oc_bundle_automatic_version
  value: {{ .Values.OperationsCenter.CasC.Retriever.ocBundleAutomaticVersion | quote }}
{{- end }}
{{- if .Values.OperationsCenter.CasC.Retriever.scmPollingInterval }}
- name: casc_retriever_scm_polling_interval
  value: {{ .Values.OperationsCenter.CasC.Retriever.scmPollingInterval }}
{{- end }}
{{/* Both scmUsername and scmPassword are optional in the application, as ssh can be used for authenticating */}}
{{- if $secret }}
  {{- if $secret.scmUsername }}
- name: casc_retriever_scm_username
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $secret.scmUsername }}
      optional: true
  {{- end }}
  {{- if $secret.scmPassword }}
- name: casc_retriever_scm_password
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $secret.scmPassword }}
      optional: true
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Template to define common resources for init container and sidecar
*/}}
{{- define "oc.casc_retriever.common.resources" -}}
limits:
  {{- $cascCpuLimit := default .Values.OperationsCenter.CasC.Retriever.Resources.Limits.Cpu .Values.OperationsCenter.CasC.Retriever.Cpu }}
  {{- if ne ($cascCpuLimit | toString) "0" }}
  cpu: "{{ $cascCpuLimit }}"
  {{- end }}
  memory: "{{ default .Values.OperationsCenter.CasC.Retriever.Resources.Limits.Memory .Values.OperationsCenter.CasC.Retriever.Memory }}"
  {{- if .Values.OperationsCenter.CasC.Retriever.Resources.Limits.EphemeralStorage }}
  ephemeral-storage: {{ .Values.OperationsCenter.CasC.Retriever.Resources.Limits.EphemeralStorage }}
  {{- end }}
requests:
  cpu: "{{ .Values.OperationsCenter.CasC.Retriever.Resources.Requests.Cpu }}"
  memory: "{{ .Values.OperationsCenter.CasC.Retriever.Resources.Requests.Memory }}"
  {{- if .Values.OperationsCenter.CasC.Retriever.Resources.Requests.EphemeralStorage }}
  ephemeral-storage: {{ .Values.OperationsCenter.CasC.Retriever.Resources.Requests.EphemeralStorage }}
  {{- end }}
{{- end -}}

{{/*
Template to define common volumeMounts for init container and sidecar
*/}}
{{- define "oc.casc_retriever.common.volumeMounts" -}}
{{- $secretName := "casc-retriever-secrets" }}
{{- $secret := .Values.OperationsCenter.CasC.Retriever.secrets }}
{{- if .Values.OperationsCenter.CasC.Retriever.secrets }}
  {{- $secretName = .Values.OperationsCenter.CasC.Retriever.secrets.secretName | default "casc-retriever-secrets" }}
{{- end }}
- name: jenkins-home
  mountPath: /var/jenkins_home
  readOnly: false
- name: oc-casc-bundle
  mountPath: {{ include "oc.casc_retriever_bundle_mount_point" . }}
  readOnly: false
{{- if and $secret .Values.OperationsCenter.CasC.Retriever.secrets.sshConfig }}
- name: casc-retriever-ssh-config
  mountPath: {{ include "oc.casc_retriever_ssh_config_home" . }}
{{- end }}
{{- end -}}

{{/*
Init container for casc bundle retriever definition
*/}}
{{- define "cloudbees-core.casc.retriever.initContainer" -}}
- name: casc-retriever-init-container
{{ include "oc.casc_retriever.common.image" . | indent 2}}
  env:
{{ include "oc.casc_retriever.common.envVars" . | indent 4}}
    - name: casc_retriever_init_container_mode
      value: "true"
  resources:
{{ include "oc.casc_retriever.common.resources" . | indent 4}}
  volumeMounts:
{{ include "oc.casc_retriever.common.volumeMounts" . | indent 4}}
{{- if .Values.OperationsCenter.CasC.Retriever.initContainerSecurityContext }}
  securityContext: {{ toYaml .Values.OperationsCenter.CasC.Retriever.initContainerSecurityContext | nindent 4 }}
{{- end }}
{{- end -}}

{{/*
CasC bundle retriever definition
*/}}
{{- define "cloudbees-core.casc.retriever" -}}
{{- if .Values.OperationsCenter.CasC.Retriever.Enabled }}
{{- $secretName := "casc-retriever-secrets" }}
{{- $secret := .Values.OperationsCenter.CasC.Retriever.secrets }}
{{- if .Values.OperationsCenter.CasC.Retriever.secrets }}
  {{- $secretName = .Values.OperationsCenter.CasC.Retriever.secrets.secretName | default "casc-retriever-secrets" }}
{{- end }}
- name: casc-retriever
{{ include "oc.casc_retriever.common.image" . | indent 2}}
  env:
{{ include "oc.casc_retriever.common.envVars" . | indent 4}}
    - name: casc_retriever_init_container_mode
      value: "false"
    {{- /*
      operations center integration
    */}}
    - name: casc_retriever_cbci_url
      value: http://localhost:{{ .Values.OperationsCenter.ContainerPort }}{{ include "oc.contextpath" . }}/
  {{- if .Values.OperationsCenter.CasC.Retriever.githubWebhooksEnabled -}}
    {{- /*
      github webhooks
    */}}
    - name: casc_retriever_github_webhooks_enabled
      value: {{ .Values.OperationsCenter.CasC.Retriever.githubWebhooksEnabled | default true | quote }}
    {{- if and $secret $secret.githubWebhookSecret }}
    - name: casc_retriever_github_webhook_secret
      valueFrom:
        secretKeyRef:
          name: {{ $secretName }}
          key: {{ $secret.githubWebhookSecret }}
          optional: true
    {{- end }}
  {{- end }}
    {{- /*
      email notifications
    */}}
    - name: casc_retriever_email_bundle_update_active
      value: {{ .Values.OperationsCenter.CasC.Retriever.emailBundleUpdateActive | default false | quote }}
  {{- if .Values.OperationsCenter.CasC.Retriever.emailBundleUpdateActive -}}
      {{- if .Values.OperationsCenter.CasC.Retriever.emailUpdateSubject }}
    - name: casc_retriever_email_bundle_update_subject
      value: {{ .Values.OperationsCenter.CasC.Retriever.emailUpdateSubject }}
      {{- end }}
      {{- if .Values.OperationsCenter.CasC.Retriever.emailBundleUpdateBody }}
    - name: casc_retriever_email_bundle_update_body
      value: {{ .Values.OperationsCenter.CasC.Retriever.emailBundleUpdateBody }}
      {{- end }}
      {{- if .Values.OperationsCenter.CasC.Retriever.emailBundleUpdateList }}
    - name: casc_retriever_email_bundle_update_list
      value: {{ .Values.OperationsCenter.CasC.Retriever.emailBundleUpdateList }}
      {{- end }}
      {{- if  .Values.OperationsCenter.CasC.Retriever.smtpAuthMethods }}
    - name: quarkus_mailer_auth_methods
      value: {{ .Values.OperationsCenter.CasC.Retriever.smtpAuthMethods }}
      {{- end }}
      {{- if .Values.OperationsCenter.CasC.Retriever.emailBundleUpdateFrom }}
    - name: casc_retriever_email_bundle_update_from
      value: {{ .Values.OperationsCenter.CasC.Retriever.emailBundleUpdateFrom }}
      {{- end }}
      {{- if .Values.OperationsCenter.CasC.Retriever.smtpHost }}
    - name: quarkus_mailer_host
      value: {{ .Values.OperationsCenter.CasC.Retriever.smtpHost }}
      {{- end }}
      {{- if .Values.OperationsCenter.CasC.Retriever.smtpPort | quote }}
    - name: quarkus_mailer_port
      value: {{ .Values.OperationsCenter.CasC.Retriever.smtpPort | quote }}
      {{- end }}
      {{- if .Values.OperationsCenter.CasC.Retriever.smtpStartTls }}
    - name: quarkus_mailer_start_tls
      value: {{ .Values.OperationsCenter.CasC.Retriever.smtpStartTls }}
      {{- end }}
    {{- if $secret }}
      {{- if $secret.smtpUsername }}
    - name: quarkus_mailer_username
      valueFrom:
        secretKeyRef:
          name: {{ $secretName }}
          key: {{ $secret.smtpUsername }}
          optional: true
      {{- end }}
      {{- if $secret.smtpPassword }}
    - name: quarkus_mailer_password
      valueFrom:
        secretKeyRef:
          name: {{ $secretName }}
          key: {{ $secret.smtpPassword }}
          optional: true
      {{- end }}
    {{- end  }}
  {{- end  }}
    {{- /*
      internal use, you probably don't need to change
    */}}
    - name: quarkus_http_port
      value: {{ .Values.OperationsCenter.CasC.Retriever.containerPort | default 9090 | quote }}
    {{- /*
      hard code the "admin" user but allow user to choose the password
    */}}
    {{- if and $secret $secret.adminPassword}}
    - name: quarkus_security_users_embedded_users_admin
      valueFrom:
        secretKeyRef:
          name: {{ $secretName }}
          key: {{ $secret.adminPassword | trim }}
          optional: true
    {{- end }}
  ports:
    - name: retriever-port
      containerPort: {{ .Values.OperationsCenter.CasC.Retriever.port | default 9090 }}
      protocol: TCP
  resources:
{{ include "oc.casc_retriever.common.resources" . | indent 4}}
  volumeMounts:
{{ include "oc.casc_retriever.common.volumeMounts" . | indent 4}}
{{- end }}
{{- if .Values.OperationsCenter.CasC.Retriever.containerSecurityContext}}
  securityContext: {{ toYaml .Values.OperationsCenter.CasC.Retriever.containerSecurityContext | nindent 4 }}
{{- end}}
{{- end -}}

{{- define "casc-retriever.service.annotations" -}}
{{- if and (eq .Values.OperationsCenter.Platform "eks") (.Values.OperationsCenter.CasC.Retriever.Enabled) -}}
alb.ingress.kubernetes.io/healthcheck-path: /casc-retriever/status
{{- end -}}
{{- end -}}
