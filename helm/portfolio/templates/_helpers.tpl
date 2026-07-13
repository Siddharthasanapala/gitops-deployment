{{/*
Chart name, used for the app.kubernetes.io/name label.
*/}}
{{- define "portfolio.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{/*
Resource name — deliberately just the release name (e.g. "portfolio-helm"),
not the chart+release concatenation `helm create` scaffolds by default, so
resource names stay as plain as k8s/raw's (Phase 3) rather than doubling up.
*/}}
{{- define "portfolio.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "portfolio.labels" -}}
app.kubernetes.io/name: {{ include "portfolio.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "portfolio.selectorLabels" -}}
app.kubernetes.io/name: {{ include "portfolio.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
