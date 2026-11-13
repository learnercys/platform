#!/usr/bin/env bash
# Static checks for everything in this repo. Tools run from pinned container
# images, so the only local requirements are Docker and Helm.
set -euo pipefail
cd "$(dirname "$0")/.."
HELM=${HELM:-helm}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Placeholder inputs for charts that need files from the service repos.
IN=$(mktemp -d); trap 'rm -rf "$OUT" "$IN"' EXIT
SQL="$IN/001_init.sql"; echo "SELECT 1;" > "$SQL"
CFG="$IN/gateway.yaml"; echo "routes: {}" > "$CFG"

step "helm lint + render"
"$HELM" lint charts/service-lib charts/dev-deps charts/observability \
  charts/event-pipeline charts/ledger charts/llm-gateway --set keycloak.realm=x --set config=x --quiet
"$HELM" template ep charts/event-pipeline -n event-pipeline --set-file "migrations.files.001_init\.sql=$SQL" > "$OUT/event-pipeline.yaml"
"$HELM" template ledger charts/ledger -n ledger --set-file "migrations.files.001_init\.sql=$SQL" > "$OUT/ledger.yaml"
"$HELM" template gw charts/llm-gateway -n llm-gateway --set-file "config=$CFG" > "$OUT/llm-gateway.yaml"
"$HELM" template obs charts/observability -n observability > "$OUT/observability.yaml"
"$HELM" template deps charts/dev-deps -n deps --set-string keycloak.realm=placeholder > "$OUT/dev-deps.yaml"
echo "rendered $(cat "$OUT"/*.yaml | grep -c '^kind:') objects"

step "kubeconform: rendered manifests against the Kubernetes 1.35 schemas"
docker run --rm -v "$OUT:/m" ghcr.io/yannh/kubeconform:v0.8.0 \
  -strict -summary -kubernetes-version 1.35.0 /m

step "trivy: Kubernetes misconfigurations in the service charts (HIGH/CRITICAL)"
# dev-deps and observability are local-only stand-ins and aren't held to the
# production bar (the collector reads host logs as root, by design).
mkdir -p "$OUT/services" && mv "$OUT"/{event-pipeline,ledger,llm-gateway}.yaml "$OUT/services/"
docker run --rm -v "$OUT/services:/m" aquasec/trivy:0.76.2 config --quiet \
  --severity HIGH,CRITICAL --exit-code 1 /m

step "terraform fmt + validate"
docker run --rm -v "$PWD/infra/terraform:/tf" -w /tf hashicorp/terraform:1.14 fmt -recursive -check
docker run --rm -v "$PWD/infra/terraform:/tf" -w /tf/envs/staging --entrypoint sh hashicorp/terraform:1.14 \
  -c 'terraform init -backend=false -input=false >/dev/null && terraform validate'

step "tflint (AWS ruleset)"
docker run --rm -v "$PWD/infra/terraform:/data" -w /data -e TFLINT_CONFIG_FILE=/data/.tflint.hcl \
  -e TFLINT_PLUGIN_DIR=/data/.tflint.d --entrypoint sh ghcr.io/terraform-linters/tflint:v0.66.0 \
  -c 'tflint --init >/dev/null && tflint --recursive'

step "trivy: Terraform misconfigurations (HIGH/CRITICAL, accepted ones in .trivyignore)"
docker run --rm -v "$PWD:/src" -w /src aquasec/trivy:0.76.2 config --quiet \
  --severity HIGH,CRITICAL --ignorefile .trivyignore --exit-code 1 \
  --skip-dirs infra/terraform/envs/staging/.terraform infra/terraform

printf '\n\033[1mPASS\033[0m\n'
