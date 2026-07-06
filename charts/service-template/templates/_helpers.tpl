{{- define "service-template.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "service-template.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "service-template.labels" -}}
app.kubernetes.io/name: {{ include "service-template.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: {{ include "service-template.name" . }}
team: {{ .Values.team | quote }}
env: {{ .Release.Namespace }}
{{- end -}}

{{- define "service-template.selectorLabels" -}}
app.kubernetes.io/name: {{ include "service-template.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
