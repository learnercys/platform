variable "name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "services" {
  description = "Service account -> the AWS permissions its pods get."
  type = map(object({
    namespace       = string
    service_account = string
    statements = list(object({
      actions   = list(string)
      resources = list(string)
    }))
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
