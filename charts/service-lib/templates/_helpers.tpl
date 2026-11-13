{{/*
service-lib: shared templates for the platform's service charts.

A service chart lists its processes under `components`; each one becomes a
Deployment (plus a Service, HPA and PDB when configured). Every pod gets the
same hardening and the same OpenTelemetry settings, so a new service inherits
them by default instead of by copy-paste.

Usage in a service chart:

  {{- include "service-lib.all" . }}
*/}}

{{- define "service-lib.labels" -}}
app.kubernetes.io/part-of: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
{{- if .name }}
app.kubernetes.io/name: {{ .name }}
{{- end }}
{{- end }}

{{- define "service-lib.selector" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/name: {{ .name }}
{{- end }}

{{- define "service-lib.fullname" -}}
{{- printf "%s-%s" .root.Release.Name .name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "service-lib.image" -}}
{{- $img := merge (default dict .c.image) .root.Values.image -}}
{{- printf "%s:%s" $img.repository (toString $img.tag) }}
{{- end }}

{{- define "service-lib.serviceAccountName" -}}
{{- default (printf "%s" .root.Release.Name) .root.Values.serviceAccount.name }}
{{- end }}

{{/* Environment shared by every container: OpenTelemetry resource and exporter settings. */}}
{{- define "service-lib.otelEnv" -}}
- name: OTEL_SERVICE_NAME
  value: {{ .name | quote }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ printf "service.namespace=%s,deployment.environment=%s" .root.Chart.Name .root.Values.global.environment | quote }}
{{- with .root.Values.global.otel.endpoint }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ . | quote }}
{{- end }}
- name: OTEL_TRACES_SAMPLER
  value: parentbased_traceidratio
- name: OTEL_TRACES_SAMPLER_ARG
  value: {{ .root.Values.global.otel.sampleRatio | quote }}
{{- end }}

{{- define "service-lib.podSecurityContext" -}}
runAsNonRoot: true
{{- /* Numeric UID: the kubelet can only verify non-root for numeric users. */}}
runAsUser: {{ default .root.Values.runAsUser (and .c .c.runAsUser) }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "service-lib.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
