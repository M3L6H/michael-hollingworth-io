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

variable "env" {
  type        = string
  description = "The current environment"
}

variable "is_prod" {
  type        = string
  description = "Is the current environment a prod environment"
}

variable "client_vpc_id" {
  type        = string
  description = "Client VPC ID"
}

variable "client_vpc_public_subnets" {
  type        = list(string)
  description = "List of public subnets in the client VPC"
}

variable "client_vpc_public_subnet_cidrs" {
  type        = list(string)
  description = "List of public subnet CIDRs in the client VPC"
}

variable "ips_allowlist" {
  type        = list(string)
  description = "List of IP CIDRs to allowlist. Defaults to 0.0.0.0/0"
  default     = ["0.0.0.0/0"]
}

variable "s3_file_expiration" {
  type        = number
  description = "Length of time to hold on to files"
  default     = 90
}

variable "default_tags" {
  type        = map
  description = "Map of default tags to apply to resources"
}

# AWS data
provider "aws" {
  profile = "michaelhollingworth-io-tf"
}

data "aws_region" "current" {
  provider = aws
}

data "aws_caller_identity" "current" {
  provider = aws
}

# Local values
locals {
  client_alb_access_logs_bucket = "${var.stack}-client-alb-access-logs"
}

# Bucket to hold client_alb access logs
module "client_alb_access_logs" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = local.client_alb_access_logs_bucket

  force_destroy            = true
  control_object_ownership = true

  attach_elb_log_delivery_policy    = true
  attach_lb_log_delivery_policy     = true
  attach_access_log_delivery_policy = true

  access_log_delivery_policy_source_accounts = [data.aws_caller_identity.current.account_id]

  lifecycle_rule = [
    {
      id      = "expire_all_files"
      enabled = true

      filter = {}

      expiration = {
        days = var.s3_file_expiration
      }
    }
  ]

  tags = merge(var.default_tags, {
    Name = local.client_alb_access_logs_bucket
  })
}

# Security group for the client_alb
# Allows HTTP(S) traffic and port 3000 egress traffic
resource "aws_security_group" "client_alb" {
  name        = "${var.stack}-client-alb-sg"
  description = "Allows HTTP & HTTPS ingress traffic. Allows port 3000 egress traffic."
  vpc_id      = var.client_vpc_id

  tags = merge(var.default_tags, {
    Name = "${var.stack}-client-alb-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "client_http" {
  for_each = toset(var.ips_allowlist)

  security_group_id = aws_security_group.client_alb.id

  description = "Allow inbound HTTP traffic"

  cidr_ipv4   = each.key
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"

  tags = merge(var.default_tags, {
    Name = "${var.stack}-http-in"
  })
}

resource "aws_vpc_security_group_ingress_rule" "client_https" {
  for_each = toset(var.ips_allowlist)

  security_group_id = aws_security_group.client_alb.id

  description = "Allow inbound HTTPS traffic"

  cidr_ipv4   = each.key
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"

  tags = merge(var.default_tags, {
    Name = "${var.stack}-https-in"
  })
}

resource "aws_vpc_security_group_egress_rule" "client_3k" {
  for_each = toset(var.client_vpc_public_subnet_cidrs)

  security_group_id = aws_security_group.client_alb.id

  description = "Allow outbound traffic on port 3000"

  cidr_ipv4   = each.key
  from_port   = 3000
  to_port     = 3000
  ip_protocol = "tcp"

  tags = merge(var.default_tags, {
    Name = "${var.stack}-port-3000-out"
  })
}

# Cert for the TLS listener on the client load balancer
resource "aws_acm_certificate" "client_cert" {
  domain_name       = var.is_prod ? "michaelhollingworth.io" : "${var.env}.michaelhollingworth.io"
  validation_method = "DNS"

  subject_alternative_names = [var.is_prod ? "*.michaelhollingworth.io" : "*.${var.env}.michaelhollingworth.io"]

  tags = var.default_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ALB fronting the client ASG
# Listens on 80 (HTTP connections) and redirects to 443
# Listens on 443 (HTTPS connections) and forwards to client ASG on 3000
module "client_alb" {
  source = "terraform-aws-modules/alb/aws"

  name = "client-alb"

  load_balancer_type    = "application"
  create_security_group = false

  vpc_id  = var.client_vpc_id
  subnets = var.client_vpc_public_subnets
  security_groups = [aws_security_group.client_alb.id]

  access_logs = {
    bucket  = local.client_alb_access_logs_bucket
    enabled = true
  }

  target_groups = [
    {
      name_prefix      = "client"
      backend_protocol = "HTTP"
      backend_port     = 3000
      target_type      = "instance"
    }
  ]

  https_listeners = [
    {
      port               = 443
      protocol           = "HTTPS"
      certificate_arn    = aws_acm_certificate.client_cert.arn
      target_group_index = 0
    }
  ]

  http_tcp_listeners = [
    {
      port        = 80
      protocol    = "HTTP"
      action_type = "redirect"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  ]

  tags = var.default_tags
}

# Client ALB outputs
output "client_alb_dns" {
  value       = module.client_alb.lb_dns_name
  description = "DNS name of the client ALB"
}

output "client_alb_target_group_arns" {
  value       = module.client_alb.target_group_arns
  description = "Target group ARNs of the client ALB"
}
