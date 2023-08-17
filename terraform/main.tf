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
  description = "The environment to provision"
  default     = "dev"

  validation {
    condition     = var.env == "dev" || var.env == "prod"
    error_message = "The env value should be either dev or prod"
  }
}

variable "client_cidr_block" {
  type        = string
  description = "The CIDR block used by the client VPC"
}

variable "server_cidr_block" {
  type        = string
  description = "The CIDR block used by the server VPC"
}

locals {
  # Stack name derived from project name and environment
  stack = "${var.project}-${var.env}"
}

locals {
  default_tags = {
    Stack = local.stack
  }
}

provider "aws" {
  profile = "michaelhollingworth-io-tf"
}

module "client-vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${local.stack}-client-vpc"
  cidr = var.client_cidr_block

  tags = local.default_tags
}

module "server-vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${local.stack}-server-vpc"
  cidr = var.server_cidr_block

  tags = local.default_tags
}
