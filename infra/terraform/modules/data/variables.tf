variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets for the database and cache."
  type        = list(string)
}

variable "client_security_group_id" {
  description = "Security group of the cluster nodes allowed to connect."
  type        = string
}

variable "postgres_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.small"
}

variable "multi_az" {
  description = "Standby replicas in a second AZ (on in production)."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
