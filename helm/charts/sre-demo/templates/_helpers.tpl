{{/*
Common labels applied to every resource.
*/}}
{{- define "sre-demo.labels" -}}
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/part-of: sre-demo
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Alloy OTLP endpoint — referenced by every boutique service.
*/}}
{{- define "sre-demo.alloyEndpoint" -}}
http://alloy.{{ .Values.namespaces.observability }}.svc.cluster.local:4317
{{- end }}

{{/*
Boutique image for a given service name.
Usage: {{ include "sre-demo.boutiqueImage" (dict "service" "frontend" "Values" .Values) }}
*/}}
{{- define "sre-demo.boutiqueImage" -}}
{{ .Values.global.boutique.registry }}/{{ .service }}:{{ .Values.global.boutique.imageTag }}
{{- end }}
