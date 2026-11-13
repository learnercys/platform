# 4. AWS infrastructure in Terraform

**Status:** accepted

## Context

The services need a Kubernetes cluster, Postgres, Redis, SNS/SQS, image
registries, and a way for CI to push images. All of it has to be reviewable,
reproducible and least-privilege.

## Decision

- **Community modules for undifferentiated plumbing:** `terraform-aws-modules`
  `vpc` (~> 6.0) and `eks` (~> 21.0). Hand-writing EKS adds risk, not value.
- **Own modules for what's specific to these services:**

  | Module | What it encodes |
  |---|---|
  | `messaging` | the event-pipeline topology: SNS topic → one SQS queue + DLQ per consumer, raw delivery, queue policies that only accept this topic, a customer-managed KMS key with rotation, and a CloudWatch alarm the moment a DLQ isn't empty |
  | `data` | RDS Postgres 17 and ElastiCache (Valkey) in private subnets, reachable only from the node security group; encryption at rest and in transit, TLS enforced on Postgres, master password generated and kept in Secrets Manager by RDS (never in state) |
  | `service-identity` | one IAM role per Kubernetes service account through **EKS Pod Identity**, scoped to the exact actions and ARNs a service uses |
  | `ecr` | immutable tags, scan on push, lifecycle policy |
  | `github-oidc` | GitHub Actions on `main` of the three repos assume a push-only role through OIDC: no AWS keys stored in GitHub |

- **Pod Identity over IRSA.** No per-cluster OIDC provider and no service
  account annotations, and roles can be reused across clusters. Only
  event-pipeline gets AWS permissions (publish to its topic, consume its
  queues, use its key). Ledger and gateway need none.
- **State** in S3 with native lockfiles (`use_lockfile`); the bucket is passed
  at `init`.
- **Static checks in CI:** `terraform fmt`/`validate`, `tflint` with the AWS
  ruleset, and Trivy's misconfiguration scan with HIGH and CRITICAL findings
  failing the build. Trivy found the SNS topic on the AWS-managed key (fixed
  with a CMK) and an EKS API open to `0.0.0.0/0`, fixed with a required
  `cluster_admin_cidrs` whose validation rejects `0.0.0.0/0`. Two findings are
  accepted with written reasons in `.trivyignore`: a public, CIDR-restricted
  API endpoint, and node egress through NAT.

## Consequences

- **This has been validated, linted and scanned, but not applied.** Applying
  it creates billable resources (EKS control plane, NAT gateway, RDS,
  ElastiCache), roughly $350–400/month for staging as sized, at on-demand prices. A `plan` needs
  an AWS account and credentials.
- Staging trades availability for cost: one NAT gateway, single-AZ RDS and
  Redis, deletion protection off. Production flips those variables.
- Not included yet: External Secrets Operator and AWS Load Balancer Controller
  installation (Helm releases on the cluster), WAF, and VPC endpoints to lock
  down node egress.
