# Configure terraform
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.12"
    }
  }

  required_version = ">= 1.2.0"
}

# Variables
variable "stack" {
  type        = string
  description = "Name of the stack"
}

variable "client_kp_public_key" {
  type        = string
  description = "Client KP public key"
}

variable "default_tags" {
  type        = map
  description = "Map of default tags to apply to resources"
}

# Key pair used to ssh into EC2 instances in the client ASG
resource "aws_key_pair" "client_asg" {
  key_name   = "${var.stack}-client-kp"
  public_key = var.client_kp_public_key

  tags = var.default_tags
}
