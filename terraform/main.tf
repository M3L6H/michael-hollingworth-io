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

variable "client_vpc_first_ip" {
  type        = string
  description = "The first IP for the client VPC"
}

variable "server_vpc_first_ip" {
  type        = string
  description = "The first IP for the server VPC"
}

provider "aws" {
  profile = "michaelhollingworth-io-tf"
}

data "aws_region" "current" {
  provider = aws
}

locals {
  # Split the client/server vpc first IPs into parts
  client_vpc_first_ip_parts = split(".", var.client_vpc_first_ip)
  server_vpc_first_ip_parts = split(".", var.server_vpc_first_ip)

  # IP network prefixes
  main_vpc_ip_network_prefix = 16
  subnet_ip_network_prefix   = 18

  # Stack name derived from project name and environment
  stack = "${var.project}-${var.env}"

  # Subnet prefixes
  client_subnet_ip_prefixes = [0, 64, 128]

  # AZ suffixes
  az_suffixes = ["a", "b", "c"]
}

locals {
  default_tags = {
    Stack = local.stack
  }

  azs = [for s in local.az_suffixes : "${data.aws_region.current.name}${s}"]

  client_vpc_cidr_block = "${var.client_vpc_first_ip}/${local.main_vpc_ip_network_prefix}"
  client_subnet_cidrs   = [for p in local.client_subnet_ip_prefixes : "${local.client_vpc_first_ip_parts[0]}.${local.client_vpc_first_ip_parts[1]}.${p}.0/${local.subnet_ip_network_prefix}"]
  server_vpc_cidr_block = "${var.server_vpc_first_ip}/${local.main_vpc_ip_network_prefix}"
}

module "client-vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${local.stack}-client-vpc"
  cidr = local.client_vpc_cidr_block

  azs            = local.azs
  public_subnets = local.client_subnet_cidrs

  tags = local.default_tags
}

module "server-vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${local.stack}-server-vpc"
  cidr = local.server_vpc_cidr_block

  tags = local.default_tags
}
