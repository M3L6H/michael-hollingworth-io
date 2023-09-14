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

variable "az_suffixes" {
  type        = list(string)
  description = "List of AZ suffixes"
}

variable "client_asg_instance_type" {
  type        = string
  description = "Client ASG instance type"
}

variable "client_asg_ami" {
  type        = string
  description = "Client ASG AMI"
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

variable "client_codepipeline_s3_bucket_arn" {
  type        = string
  description = "ARN of the client codepipeline s3 bucket"
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

variable "client_alb_target_group_arns" {
  type        = list(string)
  description = "List of target group ARNs for the client ALB"
}

variable "ssh_ips_allowlist" {
  type        = list(string)
  description = "List of IP CIDRs to allowlist for ssh"
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

# Key pair used to ssh into EC2 instances in the client ASG
resource "aws_key_pair" "client_asg" {
  key_name   = "${var.stack}-client-kp"
  public_key = var.client_kp_public_key

  tags = var.default_tags
}

# Security group for the client_asg
# Allows port 3000 traffic
# Allows egress traffic on 443
resource "aws_security_group" "client_asg" {
  name        = "${var.stack}-client-asg-sg"
  description = "Client ASG security group"
  vpc_id      = var.client_vpc_id

  tags = merge(var.default_tags, {
    Name = "${var.stack}-client-asg-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "client_3k" {
  for_each = toset(var.client_vpc_public_subnet_cidrs)

  security_group_id = aws_security_group.client_asg.id

  description = "Allow inbound traffic from port 3000"

  cidr_ipv4   = each.key
  from_port   = 3000
  to_port     = 3000
  ip_protocol = "tcp"

  tags = merge(var.default_tags, {
    Name = "${var.stack}-client-asg-3k-in"
  })
}

resource "aws_vpc_security_group_ingress_rule" "client_ssh" {
  for_each = toset(var.ssh_ips_allowlist)

  security_group_id = aws_security_group.client_asg.id

  description = "Allow inbound SSH traffic"

  cidr_ipv4   = each.key
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"

  tags = merge(var.default_tags, {
    Name = "${var.stack}-client-asg-ssh-in"
  })
}

resource "aws_vpc_security_group_egress_rule" "client_443" {
  security_group_id = aws_security_group.client_asg.id

  description = "Allow outbound 443 traffic"

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"

  tags = merge(var.default_tags, {
    Name = "${var.stack}-client-asg-443-out"
  })
}

# Client instance IAM role definition
data "aws_iam_policy_document" "client_instance_profile_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "client_instance_profile" {
  name               = "${var.stack}-client-instance-role"
  assume_role_policy = data.aws_iam_policy_document.client_instance_profile_assume_role.json
}

resource "aws_iam_instance_profile" "client_instance_profile" {
  name = "${var.stack}-client-instance-profile"
  role = aws_iam_role.client_instance_profile.name
}

data "aws_iam_policy_document" "client_instance_profile" {
  statement {
    effect = "Allow"

    actions = [
      "s3:Get*",
      "s3:List*"
    ]

    resources = [
      "arn:aws:s3:::aws-codedeploy-${data.aws_region.current.name}/*",
      var.client_codepipeline_s3_bucket_arn,
      "${var.client_codepipeline_s3_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "client_instance_profile" {
  role   = aws_iam_role.client_instance_profile.name
  policy = data.aws_iam_policy_document.client_instance_profile.json
}

# Launch template for the client asg
resource "aws_launch_template" "client_asg" {
  name        = "${var.stack}-client-asg-lt"
  description = "Client ASG launch template"

  image_id      = var.client_asg_ami
  instance_type = var.client_asg_instance_type

  key_name = aws_key_pair.client_asg.key_name

  user_data = filebase64("${path.module}/scripts/client_user_data.sh")

  iam_instance_profile {
    arn = aws_iam_instance_profile.client_instance_profile.arn
  }

  vpc_security_group_ids = [aws_security_group.client_asg.id]
}

# Client autoscaling group
resource "aws_autoscaling_group" "client_asg" {
  count = length(var.az_suffixes)

  name = "${var.stack}-client-asg-${var.az_suffixes[count.index]}"

  min_size                  = var.client_asg_min_size
  max_size                  = var.client_asg_max_size
  desired_capacity          = var.client_asg_desired
  wait_for_capacity_timeout = 0
  health_check_type         = "EC2"
  health_check_grace_period = 60
  vpc_zone_identifier       = [var.client_vpc_public_subnets[count.index]]

  target_group_arns = var.client_alb_target_group_arns

  termination_policies  = ["OldestLaunchConfiguration", "OldestInstance", "Default"]
  max_instance_lifetime = 864000

  instance_refresh {
    strategy = "Rolling"
    triggers = ["tag"]
  }

  launch_template {
    name    = aws_launch_template.client_asg.name
    version = aws_launch_template.client_asg.latest_version
  }

  tag {
    key                 = "Stack"
    value               = var.stack
    propagate_at_launch = true
  }

  tag {
    key                 = "Launch Version"
    value               = aws_launch_template.client_asg.latest_version
    propagate_at_launch = true
  }
}

# Client ASG outputs
output client_asg_names {
  value       = aws_autoscaling_group.client_asg[*].name
  description = "List of names of the client ASGs"
}
