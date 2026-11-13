# 1. One library chart for every service

**Status:** accepted

## Context

Three services (seven processes in all) need the same production basics:

- non-root pods with a read-only root filesystem and no Linux capabilities;
- probes, resource requests and limits;
- disruption budgets, rolling updates that never drop below capacity, and
  spread across nodes;
- OpenTelemetry settings;
- a safe way to run database migrations.

Writing a chart per service by hand means seven copies of each of those, and
they drift.

## Decision

`charts/service-lib` is a Helm **library chart**. A service chart declares its
processes under `components` and calls one template:

```yaml
components:
  ingest:
    command: [/app/ingest]
    port: 8080
    probePath: /healthz
    replicas: 2
    pdb: { minAvailable: 1 }
  relay:
    command: [/app/relay]
```

```yaml
# templates/all.yaml
{{- include "service-lib.all" . }}
```

Every component gets:

| Concern | Default |
|---|---|
| Pod security | `runAsNonRoot` with a **numeric** UID (the kubelet can only verify numeric users), seccomp `RuntimeDefault`, `readOnlyRootFilesystem`, all capabilities dropped, no privilege escalation, no service-account token unless asked for, and no `*_PORT` service-link env vars |
| Availability | `maxUnavailable: 0` rolling updates, topology spread when replicas > 1, optional PDB and HPA |
| Config changes | a checksum annotation rolls pods when values change |
| Telemetry | `OTEL_SERVICE_NAME`, resource attributes, exporter endpoint and sampling from one `global.otel` block |
| Secrets | one Secret per release loaded with `envFrom`. Locally it comes from values; in AWS, External Secrets creates the same name from Secrets Manager, so pods don't change |
| Migrations | a pre-install/pre-upgrade hook Job that applies each SQL file once, in a transaction, tracked in `schema_migrations`, so upgrades are idempotent |

## Consequences

- A new service chart is ~60 lines of values. The three charts here contain
  no Deployment YAML at all.
- Trivy's Kubernetes scan of the rendered service charts reports no HIGH or
  CRITICAL findings, and CI keeps it that way.
- The library is opinionated. A service that needs a StatefulSet or sidecar
  would extend it or bring its own template; none does yet.
- The migration runner is a shell loop around `psql`. It's enough for
  forward-only SQL files. A team with many services would standardize on a
  migration tool (Atlas, goose) and run it the same way, as a hook Job.
