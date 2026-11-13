# 2. A local Kubernetes environment that mirrors AWS

**Status:** accepted

## Context

Each service repo already runs on Docker Compose. That's the fastest loop for
working on one service, but it never exercises what production adds:
multiple replicas, rolling updates, probes, security contexts, migrations as
Jobs, and the services running side by side.

## Decision

`make up` creates a **kind** cluster and deploys the same Helm charts that
would go to EKS. The AWS managed services get local stand-ins in a separate
`dev-deps` chart that is never deployed to AWS:

| AWS | Local stand-in |
|---|---|
| RDS Postgres | Postgres StatefulSet (one instance, a database per service) |
| ElastiCache | Redis |
| SNS + SQS | Moto |
| an OIDC provider | Keycloak, with the ledger realm imported |
| Managed Grafana / Prometheus / Tempo / Loki | `grafana/otel-lgtm` (all-in-one) |

The kind node maps NodePorts to **the same host ports the service repos'
Compose setups use**. Each repo's own tools (event-pipeline's load generator
and verifier, the ledger and gateway demo scripts) therefore run unchanged
against the cluster, and `make smoke` is just those tools.

Images are built from the sibling service repos and loaded into kind, so
nothing is pushed anywhere to run locally.

## Consequences

- Running it on Kubernetes found a real bug that Compose couldn't: two
  llm-gateway replicas starting together raced on `CREATE TABLE IF NOT
  EXISTS`, and one crashed. The fix (an advisory lock around the startup
  migration, with a test that runs six concurrently) went into llm-gateway.
- Another Kubernetes-only behavior surfaced too. A Service named `moto` makes
  Kubernetes inject `MOTO_PORT=tcp://…` into pods, which broke Moto's own
  `MOTO_PORT` setting. Service links are now off everywhere.
- The full stack uses about 3 GB of RAM in the kind node. Keycloak and the LGTM image are most
  of it.
- Stand-ins aren't the real thing: Moto's SQS is functional, not a
  performance model, and kind is one node. Behavior is covered; load and
  failure-domain testing need the real cluster.
