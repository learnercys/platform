output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "postgres_endpoint" {
  value = module.data.postgres_endpoint
}

output "postgres_master_secret_arn" {
  value = module.data.postgres_master_secret_arn
}

output "redis_endpoint" {
  value = module.data.redis_endpoint
}

output "topic_arn" {
  value = module.messaging.topic_arn
}

output "queue_urls" {
  value = module.messaging.queue_urls
}

output "ecr_repositories" {
  value = module.ecr.repository_urls
}

output "github_push_role_arn" {
  value = module.github_oidc.role_arn
}
