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
