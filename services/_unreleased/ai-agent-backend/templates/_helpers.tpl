{{- define "ai-agent-backend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ai-agent-backend.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "ai-agent-backend.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ai-agent-backend.configChecksum" -}}
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
{{- end -}}

{{- define "ai-agent-backend.labels" -}}
helm.sh/chart: {{ include "ai-agent-backend.chart" . }}
app.kubernetes.io/name: {{ include "ai-agent-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "ai-agent-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ai-agent-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ai-agent-backend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ai-agent-backend.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "ai-agent-backend.databaseSecretName" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecret -}}
{{- else if .Values.database.secretName -}}
{{- .Values.database.secretName -}}
{{- else if .Values.database.createSecret -}}
{{- printf "%s-db" (include "ai-agent-backend.fullname" .) -}}
{{- else -}}
{{- required "database.existingSecret or database.secretName must be set when database.createSecret is false" .Values.database.existingSecret -}}
{{- end -}}
{{- end -}}
