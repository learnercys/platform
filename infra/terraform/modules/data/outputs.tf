output "postgres_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "postgres_master_secret_arn" {
  description = "Secrets Manager secret RDS created for the master user."
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "redis_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}
