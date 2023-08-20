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

  # Buckets
  client_alb_access_logs_bucket = "${local.stack}-client-alb-access-logs"
  client_codebuild_bucket       = "${local.stack}-client-codebuild"
  client_codepipeline_bucket    = "${local.stack}-client-codepipeline"
}

module "client_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${local.stack}-client-vpc"
  cidr = local.client_vpc_cidr_block

  azs            = local.azs
  public_subnets = local.client_subnet_cidrs

  map_public_ip_on_launch = true

  tags = local.default_tags
}

module "server_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${local.stack}-server-vpc"
  cidr = local.server_vpc_cidr_block

  tags = local.default_tags
}

resource "aws_key_pair" "client_asg" {
  key_name   = "${local.stack}-client-kp"
  public_key = var.client_kp_public_key

  tags = local.default_tags
}

resource "aws_security_group" "http_traffic" {
  name        = "${local.stack}-client-http-sg"
  description = "Allows HTTP and HTTPS traffic"
  vpc_id      = module.client_vpc.vpc_id

  tags = merge(local.default_tags, {
    Name = "${local.stack}-client-http-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.http_traffic.id

  description = "Allow all inbound HTTP traffic"

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  ip_protocol = "tcp"
  to_port     = 80

  tags = merge(local.default_tags, {
    Name = "${local.stack}-http-in"
  })
}

resource "aws_security_group" "client_asg" {
  name        = "${local.stack}-client-asg-sg"
  description = "Client ASG security group"
  vpc_id      = module.client_vpc.vpc_id

  tags = merge(local.default_tags, {
    Name = "${local.stack}-client-asg-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.client_asg.id

  description = "Allow all inbound SSH traffic"

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 22
  ip_protocol = "tcp"
  to_port     = 22

  tags = merge(local.default_tags, {
    Name = "${local.stack}-client-asg-ssh-in"
  })
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.client_asg.id

  description = "Allow all outbound traffic"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = -1

  tags = merge(local.default_tags, {
    Name = "${local.stack}-client-asg-all-out"
  })
}

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
        days = 10
      }
    }
  ]

  tags = merge(local.default_tags, {
    Name = local.client_alb_access_logs_bucket
  })
}

module "client_alb" {
  source = "terraform-aws-modules/alb/aws"

  name = "client-alb"

  load_balancer_type = "application"

  vpc_id          = module.client_vpc.vpc_id
  subnets         = module.client_vpc.public_subnets
  security_groups = [aws_security_group.http_traffic.id]

  access_logs = {
    bucket  = local.client_alb_access_logs_bucket
    enabled = true
  }

  target_groups = [
    {
      name             = "client-tg"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]
}

resource "aws_launch_template" "client_asg" {
  name        = "${local.stack}-client-asg-lt"
  description = "Client ASG launch template"

  image_id      = var.client_asg_ami
  instance_type = var.client_asg_instance_type

  key_name = aws_key_pair.client_asg.key_name

  user_data = filebase64("scripts/client_user_data.sh")

  vpc_security_group_ids = [
    aws_security_group.client_asg.id,
    aws_security_group.http_traffic.id
  ]
}

resource "aws_autoscaling_group" "client_asg" {
  count = length(local.az_suffixes)

  name = "${local.stack}-client-asg-${local.az_suffixes[count.index]}"

  min_size                  = var.client_asg_min_size
  max_size                  = var.client_asg_max_size
  desired_capacity          = var.client_asg_desired
  wait_for_capacity_timeout = 0
  health_check_type         = "EC2"
  health_check_grace_period = 60
  vpc_zone_identifier       = [module.client_vpc.public_subnets[count.index]]

  target_group_arns = module.client_alb.target_group_arns

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
    value               = local.stack
    propagate_at_launch = true
  }

  tag {
    key                 = "Launch Version"
    value               = aws_launch_template.client_asg.latest_version
    propagate_at_launch = true
  }
}

module "client_codebuild_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = local.client_codebuild_bucket
  acl    = "private"

  lifecycle_rule = [
    {
      id      = "expire_all_files"
      enabled = true

      filter = {}

      expiration = {
        days = 10
      }
    }
  ]

  tags = merge(local.default_tags, {
    Name = local.client_codebuild_bucket
  })
}

data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "client_codebuild" {
  name               = "${local.stack}-client-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume_role.json
}

data "aws_iam_policy_document" "client_codebuild" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
    ]

    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:network-interface/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:Subnet"

      values = module.client_vpc.public_subnet_arns
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }
  }

  statement {
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      module.client_codebuild_bucket.s3_bucket_arn,
      "${module.client_codebuild_bucket.s3_bucket_arn}/*",
      module.client_codepipeline_bucket.s3_bucket_arn,
      "${module.client_codepipeline_bucket.s3_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "client_codebuild" {
  role   = aws_iam_role.client_codebuild.name
  policy = data.aws_iam_policy_document.client_codebuild.json
}

resource "aws_codestarconnections_connection" "github_connection" {
  name          = "github-connection"
  provider_type = "GitHub"

  tags = local.default_tags
}

resource "aws_codebuild_project" "client" {
  name          = "${local.stack}-client"
  description   = "Client CodeBuild project"
  build_timeout = "5"
  service_role  = aws_iam_role.client_codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  secondary_artifacts {
    type = "S3"

    artifact_identifier = "playwright"
    bucket_owner_access = "FULL"

    location       = local.client_codebuild_bucket
    namespace_type = "BUILD_ID"
    packaging      = "ZIP"
    path           = "test"
  }

  cache {
    type     = "S3"
    location = local.client_codebuild_bucket
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "NODE_ENV"
      value = "non_prod"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "log-group"
      stream_name = "log-stream"
    }

    s3_logs {
      status   = "ENABLED"
      location = "${local.client_codebuild_bucket}/build-log"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "client/buildspec.yml"
  }

  tags = local.default_tags
}

resource "aws_codedeploy_app" "client_codedeploy" {
  compute_platform = "Server"
  name             = "${local.stack}-client"
}

resource "aws_codedeploy_deployment_config" "client_codedeploy" {
  deployment_config_name = "${local.stack}-client"

  minimum_healthy_hosts {
    type  = "HOST_COUNT"
    value = 2
  }
}

data "aws_iam_policy_document" "codedeploy_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codedeploy_role" {
  name               = "codedeploy-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume_role.json
}

resource "aws_iam_role_policy_attachment" "AWSCodeDeployRole" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
  role       = aws_iam_role.codedeploy_role.name
}

resource "aws_codedeploy_deployment_group" "client_codedeploy" {
  app_name               = aws_codedeploy_app.client_codedeploy.name
  deployment_group_name  = "${local.stack}-client"
  service_role_arn       = aws_iam_role.codedeploy_role.arn
  deployment_config_name = aws_codedeploy_deployment_config.client_codedeploy.id

  autoscaling_groups = aws_autoscaling_group.client_asg[*].name

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}

module "client_codepipeline_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = local.client_codepipeline_bucket
  acl    = "private"

  lifecycle_rule = [
    {
      id      = "expire_all_files"
      enabled = true

      filter = {}

      expiration = {
        days = 10
      }
    }
  ]

  tags = merge(local.default_tags, {
    Name = local.client_codepipeline_bucket
  })
}

data "aws_iam_policy_document" "codepipeline_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "client_codepipeline_role" {
  name               = "client-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_role.json
}

data "aws_iam_policy_document" "client_codepipeline_policy" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObjectAcl",
      "s3:PutObject",
    ]

    resources = [
      module.client_codepipeline_bucket.s3_bucket_arn,
      "${module.client_codepipeline_bucket.s3_bucket_arn}/*"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["codestar-connections:UseConnection"]
    resources = [aws_codestarconnections_connection.github_connection.arn]
  }

  statement {
    effect = "Allow"

    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "client_codepipeline_policy" {
  name   = "client_codepipeline_policy"
  role   = aws_iam_role.client_codepipeline_role.id
  policy = data.aws_iam_policy_document.client_codepipeline_policy.json
}

resource "aws_codepipeline" "client_pipeline" {
  name     = "${local.stack}-client-pipeline"
  role_arn = aws_iam_role.client_codepipeline_role.arn

  artifact_store {
    location = local.client_codepipeline_bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github_connection.arn
        FullRepositoryId = "M3L6H/michael-hollingworth-io"
        BranchName       = "master"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.client.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        ApplicationName     = aws_codedeploy_app.client_codedeploy.name
        DeploymentGroupName = aws_codedeploy_deployment_group.client_codedeploy.deployment_group_name
      }
    }
  }
}
