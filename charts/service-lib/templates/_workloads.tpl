{{- define "service-lib.deployment" -}}
{{- $c := .c -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "service-lib.fullname" . }}
  labels: {{- include "service-lib.labels" . | nindent 4 }}
spec:
  {{- if not (and $c.autoscaling $c.autoscaling.enabled) }}
  replicas: {{ default 1 $c.replicas }}
  {{- end }}
  revisionHistoryLimit: 3
  selector:
    matchLabels: {{- include "service-lib.selector" . | nindent 6 }}
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }
  template:
    metadata:
      labels: {{- include "service-lib.labels" . | nindent 8 }}
      annotations:
        # Roll pods when the chart's config changes.
        checksum/config: {{ toJson .root.Values | sha256sum | trunc 16 }}
    spec:
      serviceAccountName: {{ include "service-lib.serviceAccountName" . }}
      enableServiceLinks: false
      automountServiceAccountToken: {{ default false .root.Values.serviceAccount.automountToken }}
      securityContext: {{- include "service-lib.podSecurityContext" . | nindent 8 }}
      terminationGracePeriodSeconds: {{ default 30 $c.terminationGracePeriodSeconds }}
      {{- if gt (int (default 1 $c.replicas)) 1 }}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: {{- include "service-lib.selector" . | nindent 14 }}
      {{- end }}
      containers:
        - name: {{ .name }}
          image: {{ include "service-lib.image" . }}
          imagePullPolicy: {{ default "IfNotPresent" .root.Values.image.pullPolicy }}
          {{- with $c.command }}
          command: {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $c.args }}
          args: {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if $c.port }}
          ports:
            - name: http
              containerPort: {{ $c.port }}
          {{- end }}
          env:
            {{- include "service-lib.otelEnv" . | nindent 12 }}
            {{- range $k, $v := merge (default dict $c.env) (default dict .root.Values.env) }}
            - name: {{ $k }}
              value: {{ tpl (toString $v) $.root | quote }}
            {{- end }}
          {{- with .root.Values.secretName }}
          envFrom:
            - secretRef:
                name: {{ tpl . $.root }}
          {{- end }}
          {{- if $c.probePath }}
          readinessProbe:
            httpGet: { path: {{ $c.probePath }}, port: http }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: {{ $c.probePath }}, port: http }
            periodSeconds: 10
            failureThreshold: 6
          {{- end }}
          resources: {{- toYaml (default .root.Values.defaultResources $c.resources) | nindent 12 }}
          securityContext: {{- include "service-lib.containerSecurityContext" . | nindent 12 }}
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
            {{- range $c.configMounts }}
            - { name: {{ .name }}, mountPath: {{ .mountPath }}, readOnly: true }
            {{- end }}
      volumes:
        - name: tmp
          emptyDir: {}
        {{- range $c.configMounts }}
        - name: {{ .name }}
          configMap: { name: {{ tpl .configMap $.root }} }
        {{- end }}
{{- end }}

{{- define "service-lib.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "service-lib.fullname" . }}
  labels: {{- include "service-lib.labels" . | nindent 4 }}
spec:
  type: {{ default "ClusterIP" .c.serviceType }}
  selector: {{- include "service-lib.selector" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .c.port }}
      targetPort: http
      {{- with .c.nodePort }}
      nodePort: {{ . }}
      {{- end }}
{{- end }}

{{- define "service-lib.hpa" -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "service-lib.fullname" . }}
  labels: {{- include "service-lib.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "service-lib.fullname" . }}
  minReplicas: {{ .c.autoscaling.minReplicas }}
  maxReplicas: {{ .c.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: {{ default 70 .c.autoscaling.cpu }} }
{{- end }}

{{- define "service-lib.pdb" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "service-lib.fullname" . }}
  labels: {{- include "service-lib.labels" . | nindent 4 }}
spec:
  {{- if .c.pdb.minAvailable }}
  minAvailable: {{ .c.pdb.minAvailable }}
  {{- else }}
  maxUnavailable: {{ default 1 .c.pdb.maxUnavailable }}
  {{- end }}
  selector:
    matchLabels: {{- include "service-lib.selector" . | nindent 6 }}
{{- end }}

{{/*
Migrations run as a Helm hook Job before install and upgrade. The runner
keeps a schema_migrations table and applies each SQL file once, in order,
inside a transaction, so re-running a release is safe.
*/}}
{{- define "service-lib.migrations" -}}
{{- $m := .root.Values.migrations -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .root.Release.Name }}-migrations
  labels: {{- include "service-lib.labels" (dict "root" .root "name" "migrations") | nindent 4 }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-10"
    helm.sh/hook-delete-policy: before-hook-creation
data:
  {{- range $file, $sql := $m.files }}
  {{ $file }}: |
    {{- $sql | nindent 4 }}
  {{- end }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .root.Release.Name }}-migrate
  labels: {{- include "service-lib.labels" (dict "root" .root "name" "migrate") | nindent 4 }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: 6
  template:
    metadata:
      labels: {{- include "service-lib.labels" (dict "root" .root "name" "migrate") | nindent 8 }}
    spec:
      restartPolicy: OnFailure
      securityContext:
        runAsNonRoot: true
        runAsUser: 70 # postgres user in the alpine image
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: migrate
          image: {{ $m.image }}
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: {{ tpl $m.secretName .root }}
                  key: {{ $m.secretKey }}
          command: ["/bin/sh", "-ec"]
          args:
            - |
              until pg_isready -d "$DATABASE_URL" -q; do echo "waiting for postgres"; sleep 2; done
              psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c \
                "CREATE TABLE IF NOT EXISTS schema_migrations (file text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
              for f in $(ls /migrations | sort); do
                if [ "$(psql "$DATABASE_URL" -tAc "SELECT 1 FROM schema_migrations WHERE file = '$f'")" = "1" ]; then
                  echo "skip  $f (already applied)"; continue
                fi
                echo "apply $f"
                psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -1 \
                  -f "/migrations/$f" \
                  -c "INSERT INTO schema_migrations (file) VALUES ('$f')"
              done
          securityContext: {{- include "service-lib.containerSecurityContext" . | nindent 12 }}
          volumeMounts:
            - { name: migrations, mountPath: /migrations }
      volumes:
        - name: migrations
          configMap: { name: {{ .root.Release.Name }}-migrations }
{{- end }}

{{- define "service-lib.serviceAccount" -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "service-lib.serviceAccountName" . }}
  labels: {{- include "service-lib.labels" (dict "root" .root "name" "") | nindent 4 }}
  {{- with .root.Values.serviceAccount.annotations }}
  annotations: {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: false
{{- end }}

{{/* Plain environment for local development. In AWS the same Secret name is
created by External Secrets from AWS Secrets Manager, so pods don't change. */}}
{{- define "service-lib.secret" -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ tpl .root.Values.secretName .root }}
  labels: {{- include "service-lib.labels" (dict "root" .root "name" "") | nindent 4 }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-20"
    helm.sh/hook-delete-policy: before-hook-creation
type: Opaque
stringData:
  {{- range $k, $v := .root.Values.secretEnv }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
{{- end }}

{{/* Render everything a service chart needs. */}}
{{- define "service-lib.all" -}}
{{- $root := . -}}
{{ include "service-lib.serviceAccount" (dict "root" $root) }}
{{- if .Values.secretEnv }}
---
{{ include "service-lib.secret" (dict "root" $root) }}
{{- end }}
{{- range $name, $c := .Values.components }}
{{- if not (eq (toString $c.enabled) "false") }}
{{- $ctx := dict "root" $root "name" $name "c" $c }}
---
{{ include "service-lib.deployment" $ctx }}
{{- if $c.port }}
---
{{ include "service-lib.service" $ctx }}
{{- end }}
{{- if and $c.autoscaling $c.autoscaling.enabled }}
---
{{ include "service-lib.hpa" $ctx }}
{{- end }}
{{- if $c.pdb }}
---
{{ include "service-lib.pdb" $ctx }}
{{- end }}
{{- end }}
{{- end }}
{{- if and .Values.migrations .Values.migrations.enabled }}
---
{{ include "service-lib.migrations" (dict "root" $root) }}
{{- end }}
{{- end }}
