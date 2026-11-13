# SNS topic fanned out to one SQS queue per consumer, each with its own
# dead-letter queue. The same topology event-pipeline's cmd/bootstrap creates
# against Moto locally.

data "aws_caller_identity" "current" {}

# A customer-managed key for the topic, so access to message contents is
# governed by this key policy (and auditable in CloudTrail), not by the
# account-wide AWS-managed SNS key.
data "aws_iam_policy_document" "key" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  statement {
    sid       = "SnsDeliversToSqs"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "events" {
  description         = "${var.name} payment events topic"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.key.json
  tags                = var.tags
}

resource "aws_kms_alias" "events" {
  name          = "alias/${var.name}-payment-events"
  target_key_id = aws_kms_key.events.key_id
}

resource "aws_sns_topic" "events" {
  name              = "${var.name}-payment-events"
  kms_master_key_id = aws_kms_key.events.arn
  tags              = var.tags
}

resource "aws_sqs_queue" "dlq" {
  for_each                  = toset(var.consumers)
  name                      = "${var.name}-${each.key}-events-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "queue" {
  for_each                   = toset(var.consumers)
  name                       = "${var.name}-${each.key}-events"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = 10 # long polling by default
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = var.tags
}

# Only this topic may send to the queues.
data "aws_iam_policy_document" "queue" {
  for_each = toset(var.consumers)
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.queue[each.key].arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "queue" {
  for_each  = toset(var.consumers)
  queue_url = aws_sqs_queue.queue[each.key].id
  policy    = data.aws_iam_policy_document.queue[each.key].json
}

resource "aws_sns_topic_subscription" "queue" {
  for_each             = toset(var.consumers)
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.queue[each.key].arn
  raw_message_delivery = true
}

# Alert as soon as anything lands in a DLQ: every message there is an event
# a consumer gave up on.
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each            = toset(var.consumers)
  alarm_name          = "${var.name}-${each.key}-dlq-not-empty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq[each.key].name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = var.alarm_topic_arns
  tags                = var.tags
}
