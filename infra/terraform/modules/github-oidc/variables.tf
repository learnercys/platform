variable "name" {
  type = string
}

variable "repositories" {
  description = "GitHub repositories (owner/name) allowed to push."
  type        = list(string)
}

variable "ecr_repository_arns" {
  type = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
