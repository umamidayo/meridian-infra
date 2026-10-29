{{- define "pipeline-observability.labels" -}}
app.kubernetes.io/name: pipeline-exporter
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: meridian
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "pipeline-observability.selector" -}}
app.kubernetes.io/name: pipeline-exporter
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
