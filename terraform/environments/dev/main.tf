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

variable "client_kp_public_key" {
  type        = string
  description = "Client KP public key"
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

variable "ips_allowlist" {
  type        = list(string)
  description = "List of IP CIDRs to allowlist. Defaults to 0.0.0.0/0"
  default     = ["0.0.0.0/0"]
}

variable "ssh_ips_allowlist" {
  type        = list(string)
  description = "List of IP CIDRs to allowlist for ssh"
}

variable "s3_file_expiration" {
  type        = number
  description = "Length of time to hold on to files"
  default     = 90
}

provider "aws" {
  profile = "michaelhollingworth-io-tf"
}

data "aws_region" "current" {
  provider = aws
}

data "aws_caller_identity" "current" {
  provider = aws
}

locals {
  # Stack name derived from project name and environment
  stack = "${var.project}-${var.env}"

  # AZ suffixes
  az_suffixes = ["a", "b", "c"]

  # Are we in a prod environment
  is_prod = var.env == "prod"
}

locals {
  default_tags = {
    Stack = local.stack
  }

  azs = [for s in local.az_suffixes : "${data.aws_region.current.name}${s}"]
}

# Network components
module "network" {
  source = "../../modules/network"

  stack = local.stack

  azs = local.azs

  client_vpc_first_ip = var.client_vpc_first_ip
  server_vpc_first_ip = var.server_vpc_first_ip

  default_tags = local.default_tags
}

# Load balancer components
module "elb" {
  source = "../../modules/elb"

  stack = local.stack

  env     = var.env
  is_prod = local.is_prod

  client_vpc_id                  = module.network.client_vpc_id
  client_vpc_public_subnets      = module.network.client_vpc_public_subnets
  client_vpc_public_subnet_cidrs = module.network.client_vpc_public_subnet_cidrs

  ips_allowlist = var.ips_allowlist

  s3_file_expiration = var.s3_file_expiration

  default_tags = local.default_tags
}

output "client_alb_dns" {
  value       = module.elb.client_alb_dns
  description = "DNS name of the client ALB"
}

# Compute components
module "compute" {
  source = "../../modules/compute"

  stack = local.stack

  client_kp_public_key = var.client_kp_public_key

  az_suffixes = local.az_suffixes

  client_asg_instance_type = var.client_asg_instance_type
  client_asg_ami           = var.client_asg_ami

  client_asg_min_size = var.client_asg_min_size
  client_asg_desired  = var.client_asg_desired
  client_asg_max_size = var.client_asg_max_size

  client_codepipeline_s3_bucket_arn = module.pipeline.client_codepipeline_s3_bucket_arn

  client_vpc_id                  = module.network.client_vpc_id
  client_vpc_public_subnets      = module.network.client_vpc_public_subnets
  client_vpc_public_subnet_cidrs = module.network.client_vpc_public_subnet_cidrs

  client_alb_target_group_arns = module.elb.client_alb_target_group_arns

  ssh_ips_allowlist = var.ssh_ips_allowlist

  default_tags = local.default_tags
}

# Pipeline components
module "pipeline" {
  source = "../../modules/pipeline"

  stack = local.stack

  env     = var.env
  is_prod = local.is_prod

  s3_file_expiration = var.s3_file_expiration

  client_asg_names = module.compute.client_asg_names

  client_vpc_public_subnet_arns = module.network.client_vpc_public_subnet_arns

  default_tags = local.default_tags
}
