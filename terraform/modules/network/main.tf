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

variable "azs" {
  type        = list(string)
  description = "List of AZs to create subnets in"
}

variable "client_vpc_first_ip" {
  type        = string
  description = "The first IP for the client VPC"
}

variable "server_vpc_first_ip" {
  type        = string
  description = "The first IP for the server VPC"
}

variable "default_tags" {
  type        = map
  description = "Map of default tags to apply to resources"
}

# Local values
locals {
  # Split the client/server vpc first IPs into parts
  client_vpc_first_ip_parts = split(".", var.client_vpc_first_ip)
  server_vpc_first_ip_parts = split(".", var.server_vpc_first_ip)

  # IP network prefixes
  main_vpc_ip_network_prefix = 16
  subnet_ip_network_prefix   = 18

  # AZ suffixes
  az_suffixes = ["a", "b", "c"]

  # Subnet prefixes
  client_subnet_ip_prefixes = [0, 64, 128]
}

# Calculate the appropriate CIDR blocks
locals {
  client_vpc_cidr_block = "${var.client_vpc_first_ip}/${local.main_vpc_ip_network_prefix}"
  client_subnet_cidrs   = [for p in local.client_subnet_ip_prefixes : "${local.client_vpc_first_ip_parts[0]}.${local.client_vpc_first_ip_parts[1]}.${p}.0/${local.subnet_ip_network_prefix}"]
  server_vpc_cidr_block = "${var.server_vpc_first_ip}/${local.main_vpc_ip_network_prefix}"
}

# VPCs
# Client VPC
# Contains all the resources running the client
# Exposed to the internet
module "client_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${var.stack}-client-vpc"
  cidr = local.client_vpc_cidr_block

  azs            = var.azs
  public_subnets = local.client_subnet_cidrs

  map_public_ip_on_launch = true

  tags = var.default_tags
}

# Client VPC outputs
output "client_vpc_id" {
  value       = module.client_vpc.vpc_id
  description = "Client VPC ID"
}

output "client_vpc_public_subnets" {
  value       = module.client_vpc.public_subnets
  description = "Client VPC public subnets"
}

output "client_vpc_public_subnet_arns" {
  value       = module.client_vpc.public_subnet_arns
  description = "Client VPC public subnet arns"
}

output "client_vpc_public_subnet_cidrs" {
  value       = local.client_subnet_cidrs
  description = "Client VPC public subnet CIDRs"
}

# Server VPC
# Contains all the server resources
# Private
module "server_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${var.stack}-server-vpc"
  cidr = local.server_vpc_cidr_block

  tags = var.default_tags
}

# Server VPC outputs
output "server_vpc_id" {
  value       = module.server_vpc.vpc_id
  description = "Server VPC ID"
}
