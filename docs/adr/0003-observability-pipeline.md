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

## Service instrumentation

Every service uses the OpenTelemetry SDK, configured only through the `OTEL_*`
variables the charts set:

| Service | Spans | Metrics |
|---|---|---|
| event-pipeline (Go) | HTTP server (`otelhttp`), every query (`otelpgx`), AWS calls (`otelaws`), and **producer/consumer spans across the outbox, SNS and SQS** | `http.server.request.duration`, `db.client.operation.duration` |
| analytics consumer (Python) | consumer span continuing the SQS message's trace, plus psycopg and Redis spans | |
| ledger (Go) | an RPC server span per call (`otelconnect`) tagged with `tenant.id`, and every query | `rpc.server.call.duration` by method and status |
| llm-gateway (Python) | FastAPI server span, plus one `chat <model>` span per provider attempt with GenAI attributes (model, tokens, finish reason, retryability), and Postgres and Redis spans | `http.server.request.duration`, `gen_ai.client.token.usage`, `gen_ai.client.operation.duration`, `gateway.cost` |

`OTEL_SEMCONV_STABILITY_OPT_IN=http` makes the Python instrumentation emit the
same stable HTTP metric as Go, so one query covers every service.

**Async hops.** A payment event crosses three boundaries that carry no HTTP
headers. The ingest request's W3C trace context is stored in the outbox row.
The relay continues it in a producer span and sends its own context as SNS
message attributes. Raw message delivery passes those to SQS, where both
consumers continue the trace. In the result, the gaps between spans *are* the
outbox polling and queueing delay.

**Polling processes don't start traces.** The relay and consumers query the
database every few hundred milliseconds while idle. Their sampler is
`ParentBased(root=never)`: they record only spans that continue an existing
trace, which their real work always does.

**Dashboards are generated** by `scripts/dashboards.py`. Every query was
checked against the series the services actually emit:
- **Service health:** request rate, server-error rate and p95 per service;
  ledger RPCs by method and status; HTTP responses by route and status;
  database p95; tokens, model latency, failed calls and spend per tenant; and
  TraceQL panels for full event journeys, the slowest requests and model
  calls.
- **Platform overview:** resources and logs.

## Consequences

- Logs and resource metrics need no service changes at all. Traces and RED
  metrics need only the standard SDK setup in each service.
- The collector runs as root with `DAC_READ_SEARCH` to read host log files.
  That's the standard trade-off for node-level log collection, and why the
  observability chart is excluded from the strict scan the service charts
  pass.
- The local backend keeps everything in memory, so restarting the LGTM pod
  clears history. Dashboard changes are picked up from the ConfigMap without
  a restart for that reason.
- Not yet: exemplars linking latency spikes to traces, alerting rules, and
  tail sampling in the collector (keep every error and slow trace, sample the
  rest) for production volumes.
