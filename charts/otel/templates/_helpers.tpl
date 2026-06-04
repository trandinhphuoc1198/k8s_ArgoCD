{{/*
Expand the name of the chart.
*/}}
{{- define "otel.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "otel.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "otel.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels — attached to all resources.
*/}}
{{- define "otel.labels" -}}
helm.sh/chart: {{ include "otel.chart" . }}
{{ include "otel.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — used in spec.selector.matchLabels
*/}}
{{- define "otel.selectorLabels" -}}
app.kubernetes.io/name: {{ include "otel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
DaemonSet Collector name
*/}}
{{- define "otel.collectorDS.name" -}}
{{- .Values.collectorDaemonSet.name }}
{{- end }}

{{/*
Aggregator (Deployment) Collector name
*/}}
{{- define "otel.collectorAgg.name" -}}
{{- .Values.collectorDeployment.name }}
{{- end }}
