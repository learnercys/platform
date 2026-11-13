variable "name" {
  description = "Prefix for every resource (e.g. platform-staging)."
  type        = string
}

variable "consumers" {
  description = "One queue + DLQ per consumer."
  type        = list(string)
  default     = ["ledger", "analytics"]
}

variable "visibility_timeout_seconds" {
  type    = number
  default = 30
}

variable "max_receive_count" {
  description = "Receives before a message moves to the DLQ. Consumers pause during database outages so transient failures don't burn these."
  type        = number
  default     = 5
}

variable "alarm_topic_arns" {
  description = "SNS topics notified when a DLQ is not empty."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
