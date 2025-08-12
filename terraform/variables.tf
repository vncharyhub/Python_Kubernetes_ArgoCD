variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "ami" {
  type    = string
  default = "ami-08c40ec9ead489470"
}

variable "key_name" {
  type        = string
  description = "Name for the key pair to create in AWS"
  default     = "k8s-learning-key"
}
