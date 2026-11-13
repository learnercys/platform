# 3. One OpenTelemetry Collector pipeline for logs, metrics and traces

**Status:** accepted

## Context

The services log JSON to stdout and don't export telemetry yet. We want
per-service resource usage and searchable logs now, and request traces later,
without coupling the services to a particular backend.

## Decision

- An **OpenTelemetry Collector DaemonSet** on every node:
  - **logs:** tails `/var/log/pods` with `file_log` and parses JSON lines;
  - **metrics:** reads the kubelet's per-pod CPU, memory and network stats
    (`kubelet_stats`);
  - **OTLP:** receives traces and metrics from the services on the same node
    (`internalTrafficPolicy: Local`).

  A `k8s_attributes` processor tags everything with namespace, pod and
  `service.name` (from the pod's `app.kubernetes.io/name` label).
- The collector is the only thing that knows where telemetry goes. Locally
  that's `grafana/otel-lgtm`. In AWS it would be Amazon Managed Prometheus,
  X-Ray/Tempo and CloudWatch or Loki, changed in one exporter block.
- The service charts already set `OTEL_SERVICE_NAME`,
  `OTEL_EXPORTER_OTLP_ENDPOINT` and sampling for every pod, so instrumenting a
  service is purely a code change with no deployment change.
- A provisioned **Platform overview** dashboard (`charts/observability/dashboards`)
  shows CPU, memory and network per pod, log volume per service, and a live
  warnings-and-errors log panel. It was built against the series the
  collector actually produces, not guessed names.

## Consequences

- Logs and resource metrics work today with zero changes to the services.
- **Request-level traces and RED metrics are not there yet.** They need
  OpenTelemetry SDK instrumentation in each service: HTTP server spans, pgx,
  the AWS SDK, and trace-context propagation through SNS/SQS message
  attributes, so one payment can be followed from the ingest API to both
  consumers. That's the next step, and it touches the service repos.
- The collector runs as root with `DAC_READ_SEARCH` to read host log files.
  That's the standard trade-off for node-level log collection, and why the
  observability chart is excluded from the strict scan the service charts
  pass.
