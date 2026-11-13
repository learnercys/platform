#!/usr/bin/env python3
"""Generates the Grafana dashboards in charts/observability/dashboards/.

Kept as code so panels stay consistent and reviewable; the JSON files are the
build output. Every query was checked against the series the services and
the collector actually produce.

    python3 scripts/dashboards.py
"""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "charts/observability/dashboards"
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
TEMPO = {"type": "tempo", "uid": "tempo"}
APPS = "event-pipeline|ledger|llm-gateway"
NS = 'k8s_namespace_name=~"$namespace"'
# Server-side failures only: 4xx/denied/not-found are correct answers.
HTTP_ERR = 'http_response_status_code=~"5.."'
RPC_ERR = 'rpc_response_status_code=~"INTERNAL|UNAVAILABLE|UNKNOWN|DEADLINE_EXCEEDED|DATA_LOSS"'
LOG_ERR = r'|~ `(?i)"level":"(warn|warning|error)"|level=(warn|error)|\b(WARNING|ERROR)\b`'


class Board:
    def __init__(self):
        self.panels, self.y, self.next_id = [], 0, 1

    def _id(self):
        self.next_id += 1
        return self.next_id

    def row(self, title):
        self.panels.append({"id": self._id(), "type": "row", "title": title, "collapsed": False,
                            "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": []})
        self.y += 1

    def add(self, panels, h):
        x = 0
        for p in panels:
            w = p.pop("w")
            p["id"] = self._id()
            p["gridPos"] = {"x": x, "y": self.y, "w": w, "h": h}
            self.panels.append(p)
            x += w
        self.y += h


def target(expr, legend="", ds=PROM, **extra):
    return {"refId": "A", "datasource": ds, "expr": expr, "legendFormat": legend, **extra}


def ts(title, expr, unit, legend, w=12, ds=PROM, stack=False, desc="", soft_max=None):
    return {"type": "timeseries", "title": title, "description": desc, "datasource": ds, "w": w,
            "fieldConfig": {"defaults": {"unit": unit, "min": 0, "custom": {
                **({"axisSoftMax": soft_max} if soft_max is not None else {}),
                "lineWidth": 1, "fillOpacity": 10, "spanNulls": True,
                "stacking": {"mode": "normal" if stack else "none"}}}, "overrides": []},
            "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
            "targets": [target(expr, legend, ds)]}


def stat(title, expr, unit, w=6, ds=PROM, decimals=2, desc=""):
    return {"type": "stat", "title": title, "description": desc, "datasource": ds, "w": w,
            "fieldConfig": {"defaults": {"unit": unit, "decimals": decimals}, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "none", "graphMode": "area"},
            "targets": [target(expr, ds=ds)]}


def table(title, expr, w=12, desc="", rename=None):
    return {"type": "table", "title": title, "description": desc, "datasource": PROM, "w": w,
            "options": {"showHeader": True, "sortBy": [{"displayName": "Value", "desc": True}]},
            "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True},
                                                                "renameByName": rename or {}}}],
            # increase() extrapolates to fractions; these are counts.
            "targets": [target(f"round({expr})", format="table", instant=True)]}


def traces(title, query, w=24, desc=""):
    return {"type": "table", "title": title, "description": desc, "datasource": TEMPO, "w": w,
            "targets": [{"refId": "A", "datasource": TEMPO, "queryType": "traceql", "query": query,
                         "limit": 20, "tableType": "traces"}]}


def logs(title, expr, w=24):
    return {"type": "logs", "title": title, "datasource": LOKI, "w": w,
            "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                        "enableLogDetails": True},
            "targets": [target(expr, ds=LOKI)]}


def dashboard(uid, title, board, desc):
    return {
        "uid": uid, "title": title, "description": desc, "tags": ["platform"],
        "timezone": "browser", "schemaVersion": 39, "refresh": "30s",
        "time": {"from": "now-30m", "to": "now"},
        "templating": {"list": [{
            "name": "namespace", "label": "Service", "type": "custom", "multi": True,
            "includeAll": True, "query": "event-pipeline,ledger,llm-gateway", "allValue": APPS,
            "current": {"selected": True, "text": ["All"], "value": ["$__all"]}, "options": []}]},
        "panels": board.panels,
    }


def rate_by_service(metric, sel=""):
    return f'sum by (service_name) (rate({metric}{{{NS}{sel}}}[2m]))'


def overview():
    b = Board()
    b.add([{"type": "text", "title": "", "w": 24, "options": {"mode": "markdown", "content":
            "Resources and logs for every pod, from the OpenTelemetry Collector (kubelet stats + pod "
            "logs). Request rates, errors, latency and traces are on **Service health**."}}], 2)
    b.add([
        stat("CPU (cores)", f"sum(k8s_pod_cpu_usage{{{NS}}})", "none"),
        stat("Memory (working set)", f"sum(k8s_pod_memory_working_set_bytes{{{NS}}})", "bytes"),
        stat("Network in", f'sum(rate(k8s_pod_network_io_bytes_total{{{NS},direction="receive"}}[2m]))', "Bps"),
        stat("Warnings + errors / min",
             f'sum(count_over_time({{k8s_namespace_name=~"$namespace"}} {LOG_ERR} [1m])) or vector(0)',
             "none", ds=LOKI, decimals=0),
    ], 4)
    b.add([ts("CPU by pod", f"sum by (k8s_pod_name) (k8s_pod_cpu_usage{{{NS}}})", "none", "{{k8s_pod_name}}", stack=True),
           ts("Memory by pod", f"sum by (k8s_pod_name) (k8s_pod_memory_working_set_bytes{{{NS}}})", "bytes",
              "{{k8s_pod_name}}", stack=True)], 8)
    b.add([ts("Log lines / min by service",
              f'sum by (service_name) (count_over_time({{k8s_namespace_name=~"$namespace", service_name=~".+"}} [1m]))',
              "none", "{{service_name}}", ds=LOKI),
           ts("Network by namespace",
              f"sum by (k8s_namespace_name, direction) (rate(k8s_pod_network_io_bytes_total{{{NS}}}[2m]))",
              "Bps", "{{k8s_namespace_name}} {{direction}}")], 8)
    b.add([logs("Warnings and errors", f'{{k8s_namespace_name=~"$namespace"}} {LOG_ERR}')], 10)
    return dashboard("platform-overview", "Platform overview", b, "Pod resources and logs")


def service_health():
    b = Board()
    req = (f'{rate_by_service("http_server_request_duration_seconds_count")} or '
           f'{rate_by_service("rpc_server_call_duration_seconds_count")}')
    err = (f'(sum by (service_name) (rate(http_server_request_duration_seconds_count{{{NS},{HTTP_ERR}}}[5m])) '
           f'or sum by (service_name) (rate(rpc_server_call_duration_seconds_count{{{NS},{RPC_ERR}}}[5m])))'
           f' / ({rate_by_service("http_server_request_duration_seconds_count")} or '
           f'{rate_by_service("rpc_server_call_duration_seconds_count")})')
    p95 = (f'histogram_quantile(0.95, sum by (le, service_name) (rate(http_server_request_duration_seconds_bucket{{{NS}}}[5m]))) '
           f'or histogram_quantile(0.95, sum by (le, service_name) (rate(rpc_server_call_duration_seconds_bucket{{{NS}}}[5m])))')

    b.row("Requests (RED)")
    b.add([ts("Requests / s", req, "reqps", "{{service_name}}", w=8),
           ts("Server errors (5xx, Internal, Unavailable)", f"({err}) or vector(0)", "percentunit",
              "{{service_name}}", w=8, soft_max=0.05,
              desc="4xx, denied and not-found are correct answers and not counted"),
           ts("p95 latency", p95, "s", "{{service_name}}", w=8)], 8)
    b.add([table("Ledger RPCs by method and status",
                 f'sum by (rpc_method, rpc_response_status_code) (increase(rpc_server_call_duration_seconds_count{{{NS}}}[$__range]))',
                 rename={"rpc_method": "method", "rpc_response_status_code": "status", "Value": "calls"}),
           table("HTTP responses by service, route and status",
                 f'sum by (service_name, http_route, http_response_status_code) (increase(http_server_request_duration_seconds_count{{{NS}}}[$__range]))',
                 rename={"service_name": "service", "http_route": "route", "http_response_status_code": "status",
                         "Value": "requests"})], 8)
    b.add([ts("Database query p95 by service",
              f'histogram_quantile(0.95, sum by (le, service_name) (rate(db_client_operation_duration_seconds_bucket{{{NS}}}[5m])))',
              "s", "{{service_name}}", w=24)], 7)

    b.row("LLM gateway")
    b.add([
        ts("Tokens / s by model", 'sum by (gen_ai_response_model, gen_ai_token_type) (rate(gen_ai_client_token_usage_sum[5m]))',
           "none", "{{gen_ai_response_model}} {{gen_ai_token_type}}", w=8, stack=True),
        ts("Model call p95 by model",
           'histogram_quantile(0.95, sum by (le, gen_ai_request_model) (rate(gen_ai_client_operation_duration_seconds_bucket[5m])))',
           "s", "{{gen_ai_request_model}}", w=8),
        ts("Failed model calls / s by provider",
           'sum by (gen_ai_provider_name, error_type) (rate(gen_ai_client_operation_duration_seconds_count{error_type!=""}[5m]))',
           "reqps", "{{gen_ai_provider_name}} {{error_type}}", w=8,
           desc="Failures trigger the fallback chain; a steady rate here means a provider is degraded"),
    ], 8)
    b.add([table("Spend by tenant and model (selected range)",
                 'sum by (tenant_id, gen_ai_response_model) (increase(gateway_cost_USD_total[$__range]))',
                 w=24, rename={"tenant_id": "tenant", "gen_ai_response_model": "model", "Value": "USD"})], 6)

    b.row("Traces")
    b.add([traces("Full event journeys: ingest → relay → both consumers",
                  '{resource.service.name="ingest"} >> {resource.service.name="ledger-consumer"} && '
                  '{resource.service.name="ingest"} >> {resource.service.name="analytics-consumer"}',
                  desc="One payment event, followed across the outbox, SNS and SQS. Click a trace to open it.")], 9)
    b.add([traces("Slowest requests", '{kind=server && resource.service.namespace=~"$namespace"} | select(span.http.route, span.rpc.method)', w=12),
           traces("Model calls", '{span.gen_ai.request.model != nil} | select(span.gen_ai.response.model, span.gen_ai.usage.input_tokens, span.gen_ai.usage.output_tokens)', w=12)], 9)
    return dashboard("service-health", "Service health", b, "RED metrics, LLM usage and traces")


if __name__ == "__main__":
    for d in (overview(), service_health()):
        path = OUT / f"{d['uid']}.json"
        path.write_text(json.dumps(d, indent=2) + "\n")
        print(f"wrote {path.relative_to(OUT.parent.parent.parent)}")
