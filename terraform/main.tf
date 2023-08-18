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

variable "client_asg_min_size" {
  type        = number
  description = "Client ASG min size"
}

variable "client_asg_desired" {
  type        = number
  description = "Client ASG desired capacity"
}

variable "client_asg_max_size" {
  type        = number
  description = "Client ASG max size"
}

variable "client_asg_instance_type" {
  type        = string
  description = "Client ASG instance type"
  default     = "t2.micro"
}

variable "client_asg_ami" {
  type        = string
  description = "Client ASG AMI"
  default     = "ami-08a52ddb321b32a8c" # Amazon Linux 2023
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

module "client_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${local.stack}-client-vpc"
  cidr = local.client_vpc_cidr_block

  azs            = local.azs
  public_subnets = local.client_subnet_cidrs

  tags = local.default_tags
}

module "server_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${local.stack}-server-vpc"
  cidr = local.server_vpc_cidr_block

  tags = local.default_tags
}

resource "aws_launch_template" "client_asg" {
  name        = "${local.stack}-client-asg-lt"
  description = "Client ASG launch template"

  image_id      = var.client_asg_ami
  instance_type = var.client_asg_instance_type
}

resource "aws_autoscaling_group" "client_asg" {
  count = length(local.az_suffixes)

  name = "${local.stack}-client-asg-${local.az_suffixes[count.index]}"

  min_size                  = 0
  max_size                  = 1
  desired_capacity          = 1
  wait_for_capacity_timeout = 0
  health_check_type         = "EC2"
  vpc_zone_identifier       = [module.client_vpc.public_subnets[count.index]]

  launch_template {
    name    = aws_launch_template.client_asg.name
    version = "$Latest"
  }
}
