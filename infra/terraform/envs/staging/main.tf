locals {
  name = "platform-staging"
  tags = {
    project     = "platform"
    environment = "staging"
    managed-by  = "terraform"
  }
  services = ["event-pipeline", "event-pipeline-analytics", "ledger", "llm-gateway"]
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------- network

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = "10.40.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.40.0.0/19", "10.40.32.0/19", "10.40.64.0/19"]
  public_subnets  = ["10.40.96.0/22", "10.40.100.0/22", "10.40.104.0/22"]

  enable_nat_gateway = true
  single_nat_gateway = true # staging: one NAT to save cost; one per AZ in production

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# ---------------------------------------------------------------- cluster

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets

  # The API endpoint is public but only reachable from the admin CIDRs.
  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = var.cluster_admin_cidrs
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = ["m7g.large"]
      min_size       = 2
      max_size       = 6
      desired_size   = 3
    }
  }
}

# ---------------------------------------------------------------- data

module "data" {
  source = "../../modules/data"

  name                     = local.name
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  client_security_group_id = module.eks.node_security_group_id
  multi_az                 = false
  deletion_protection      = false # staging can be torn down; true in production
}

module "messaging" {
  source = "../../modules/messaging"

  name      = local.name
  consumers = ["ledger", "analytics"]
}

# ---------------------------------------------------------------- identity

# Pods get AWS permissions through EKS Pod Identity, scoped to exactly the
# resources they use. Only event-pipeline talks to AWS directly; ledger and
# llm-gateway only need their database and secrets.
module "service_identity" {
  source = "../../modules/service-identity"

  name         = local.name
  cluster_name = module.eks.cluster_name
  services = {
    event-pipeline = {
      namespace       = "event-pipeline"
      service_account = "event-pipeline"
      statements = [
        { actions = ["sns:Publish"], resources = [module.messaging.topic_arn] },
        { actions = ["kms:GenerateDataKey", "kms:Decrypt"], resources = [module.messaging.topic_kms_key_arn] },
        {
          actions = [
            "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility",
            "sqs:GetQueueAttributes",
          ]
          resources = values(module.messaging.queue_arns)
        },
      ]
    }
  }
}

module "ecr" {
  source       = "../../modules/ecr"
  repositories = local.services
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  name                = local.name
  repositories        = [for r in ["event-pipeline", "ledger", "llm-gateway"] : "${var.github_owner}/${r}"]
  ecr_repository_arns = module.ecr.repository_arns
}
