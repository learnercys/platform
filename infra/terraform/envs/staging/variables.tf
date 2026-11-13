variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_owner" {
  type    = string
  default = "learnercys"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "cluster_admin_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API (office/VPN egress IPs)."
  type        = list(string)
  validation {
    condition     = length(var.cluster_admin_cidrs) > 0 && !contains(var.cluster_admin_cidrs, "0.0.0.0/0")
    error_message = "Restrict the Kubernetes API to specific CIDRs; 0.0.0.0/0 is not allowed."
  }
}
