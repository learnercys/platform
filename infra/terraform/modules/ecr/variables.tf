variable "repositories" {
  type = list(string)
}

variable "keep_images" {
  type    = number
  default = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
