output "topic_arn" {
  value = aws_sns_topic.events.arn
}

output "queue_urls" {
  value = { for k, q in aws_sqs_queue.queue : k => q.url }
}

output "queue_arns" {
  value = { for k, q in aws_sqs_queue.queue : k => q.arn }
}

output "dlq_urls" {
  value = { for k, q in aws_sqs_queue.dlq : k => q.url }
}

output "topic_kms_key_arn" {
  description = "Publishers need kms:GenerateDataKey and kms:Decrypt on this key."
  value       = aws_kms_key.events.arn
}
