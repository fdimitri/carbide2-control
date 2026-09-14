{{/* Common helpers for the control-plane chart. */}}

{{- define "control-plane.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "control-plane.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: carbide2
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "control-plane.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
  Database connection env, shared by every process that boots ActiveRecord:
  the Rails container, the migrate hook Job, and the clock sidecar. Kept in one
  place so a credential or host change cannot land in two of the three.
*/}}
{{- define "control-plane.postgresEnv" -}}
- { name: POSTGRES_HOST,     value: "{{ .Values.postgres.clusterName }}-rw.{{ .Values.postgres.clusterNamespace }}.svc.cluster.local" }
- { name: POSTGRES_PORT,     value: "5432" }
- { name: POSTGRES_DB,       value: "{{ .Values.postgres.controlDatabaseName }}" }
- name: POSTGRES_USER
  valueFrom: { secretKeyRef: { name: {{ .Values.postgres.credentialsSecret }}, key: username } }
- name: POSTGRES_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ .Values.postgres.credentialsSecret }}, key: password } }
{{- end -}}

{{/*
  The registry host, as containerd and docker key their credentials: host[:port]
  with the scheme and any path stripped. registry.url carries a scheme and
  registry.path is a separate value, so neither may leak into the auths key --
  a dockerconfigjson keyed by anything but the bare host authenticates nothing.
*/}}
{{- define "control-plane.registryHost" -}}
{{- .Values.registry.url | trimPrefix "https://" | trimPrefix "http://" | trimSuffix "/" | splitList "/" | first -}}
{{- end -}}

{{/*
  imagePullSecrets for every pod in this chart. An authenticated registry
  (GitLab) needs one in the pod's OWN namespace: the operator builds the
  identical object in each ws-<project_id>, and this is the same thing for the
  control namespace. Renders nothing when registry.pullSecret is unset, which
  is the self-hosted case -- there the node trusts the CA and no credential
  exists to carry.
*/}}
{{- define "control-plane.imagePullSecrets" -}}
{{- if .Values.registry.pullSecret }}
imagePullSecrets:
  - name: {{ .Values.registry.pullSecret }}
{{- end }}
{{- end -}}
