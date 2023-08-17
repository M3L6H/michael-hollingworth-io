terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.12"
    }
  }

  required_version = ">= 1.2.0"
}

variable "project" {
  type        = string
  description = "Name of the project"
  default     = "michaelhollingworth-io"
}

variable "env" {
  type        = string
  description = "The environment to build provision"
  default     = "dev"

  validation {
    condition     = var.env == "dev" || var.env == "prod"
    error_message = "The env value should be either dev or prod"
  }
}

variable "server_cidr_block" {
  type        = string
  description = "The CIDR block used by the server VPC"
}

provider "aws" {
  profile = "michaelhollingworth-io-tf"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${var.project}-server-vpc-${var.env}"
  cidr = var.server_cidr_block
}
