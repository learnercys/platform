#!/usr/bin/env bash
# End-to-end checks against the cluster, using each service repo's own tools.
# The cluster maps the same host ports the repos' docker-compose setups use,
# so their scripts run unchanged.
set -euo pipefail
REPOS=${1:-..}
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "event-pipeline: 500 events (30% duplicates) through ingest -> outbox -> SNS -> SQS -> both consumers"
(
  cd "$REPOS/event-pipeline"
  mkdir -p bin && go build -o bin/ ./cmd/loadgen ./cmd/verify
  export AWS_ENDPOINT_URL=http://localhost:55000 AWS_REGION=us-east-1 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
  ./bin/loadgen -events 500 -poison 0 -run "k8s_$(date +%s)" -out bin/k8s-smoke.json | head -2
  ./bin/verify -expected bin/k8s-smoke.json -timeout 3m | tail -12
)

step "ledger: the curl demo with real Keycloak tokens"
"$REPOS/ledger/scripts/demo.sh" | grep -E '==>|HTTP|same transaction'

step "llm-gateway: fallback, cache, permissions, budget"
"$REPOS/llm-gateway/scripts/demo.sh" | grep -E '==>|"cached"|HTTP|^[0-9]{3} '

printf '\n\033[1mPASS\033[0m: all three services work end to end in Kubernetes\n'
