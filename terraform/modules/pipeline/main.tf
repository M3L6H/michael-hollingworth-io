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

variable "s3_file_expiration" {
  type        = number
  description = "Length of time to hold on to files"
}

variable "client_asg_names" {
  type        = list(string)
  description = "List of names of the client ASG"
}

variable "client_vpc_public_subnet_arns" {
  type        = list(string)
  description = "List of public subnet ARNs in the client VPC"
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
  client_codebuild_bucket    = "${var.stack}-client-codebuild"
  client_codepipeline_bucket = "${var.stack}-client-codepipeline"
}

# GitHub CodeStar connection
resource "aws_codestarconnections_connection" "github_connection" {
  name          = "github-connection"
  provider_type = "GitHub"

  tags = var.default_tags
}

# S3 bucket for CodeBuild caching and logs
module "client_codebuild_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = local.client_codebuild_bucket
  acl    = "private"

  force_destroy = true

  tags = merge(var.default_tags, {
    Name = local.client_codebuild_bucket
  })
}

# S3 bucket to store CodePipeline artifacts
module "client_codepipeline_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = local.client_codepipeline_bucket
  acl    = "private"

  force_destroy = true

  tags = merge(var.default_tags, {
    Name = local.client_codepipeline_bucket
  })
}

# Client CodePipeline bucket outputs
output "client_codepipeline_s3_bucket_arn" {
  value       = module.client_codepipeline_bucket.s3_bucket_arn
  description = "ARN of the client CodePipeline bucket"
}

# IAM role for cleanup lambda function
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cleanup_lambda" {
  name               = "${var.stack}-cleanup-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "cleanup_lambda" {
  statement {
    effect  = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectAttributes",
      "s3:ListBucket"
    ]
    resources = [
      module.client_codebuild_bucket.s3_bucket_arn,
      "${module.client_codebuild_bucket.s3_bucket_arn}/*",
      module.client_codepipeline_bucket.s3_bucket_arn,
      "${module.client_codepipeline_bucket.s3_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "cleanup_lambda" {
  role   = aws_iam_role.cleanup_lambda.name
  policy = data.aws_iam_policy_document.cleanup_lambda.json
}

resource "aws_iam_role_policy_attachment" "cleanup_lambda_basic_execution" {
  role       = aws_iam_role.cleanup_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda function for cleaning buckets
data "archive_file" "cleanup_lambda" {
  type             = "zip"
  source_file      = "${path.module}/lambda/cleanup/lambda_function.py"
  output_file_mode = "0666"
  output_path      = "${path.module}/lambda/cleanup.zip"
}

resource "aws_lambda_function" "cleanup_lambda" {
  filename      = "${path.module}/lambda/cleanup.zip"
  function_name = "${var.stack}-cleanup-lambda"
  description   = "Lambda used to clean Code* buckets"
  role          = aws_iam_role.cleanup_lambda.arn

  source_code_hash = data.archive_file.cleanup_lambda.output_base64sha256

  handler = "lambda_function.lambda_handler"
  runtime = "python3.11"
  timeout = 90

  tags = var.default_tags
}

# IAM role for cleanup scheduler
data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cleanup_scheduler" {
  name               = "${var.stack}-cleanup-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
}

data "aws_iam_policy_document" "cleanup_scheduler" {
  statement {
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.cleanup_lambda.arn]
  }
}

resource "aws_iam_role_policy" "cleanup_scheduler" {
  role   = aws_iam_role.cleanup_scheduler.name
  policy = data.aws_iam_policy_document.cleanup_scheduler.json
}

# Scheduler schedule for invoking cleanup lambda
resource "aws_scheduler_schedule" "cleanup_lambda" {
  name = "${var.stack}-cleanup-schedule"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(${var.s3_file_expiration} days)"

  target {
    arn      = aws_lambda_function.cleanup_lambda.arn
    role_arn = aws_iam_role.cleanup_scheduler.arn

    input = jsonencode({
      bucketEntries = [
        {
          bucket = local.client_codebuild_bucket
          prefixes = [
            "build-log/"
          ]
        },
        {
          bucket = local.client_codepipeline_bucket
          prefixes = [
            "michaelhollingworth-/build_outp/",
            "michaelhollingworth-/source_out/"
          ]
        }
      ]

      minAge      = var.s3_file_expiration
      backupCount = var.is_prod ? 4 : 2
    })
  }
}

# IAM role for codebuild
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
  name               = "${var.stack}-client-codebuild-role"
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

      values = var.client_vpc_public_subnet_arns
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

# Client CodeBuild project
resource "aws_codebuild_project" "client" {
  name          = "${var.stack}-client"
  description   = "Client CodeBuild project"
  build_timeout = "5"
  service_role  = aws_iam_role.client_codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  cache {
    type     = "S3"
    location = local.client_codebuild_bucket
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "NODE_ENV"
      value = var.is_prod ? "prod" : "non_prod"
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

  tags = var.default_tags
}

# Client CodeDeploy
resource "aws_codedeploy_app" "client_codedeploy" {
  compute_platform = "Server"
  name             = "${var.stack}-client"
}

resource "aws_codedeploy_deployment_config" "client_codedeploy" {
  deployment_config_name = "${var.stack}-client"

  minimum_healthy_hosts {
    type  = "HOST_COUNT"
    value = 2
  }
}

# CodeDeploy IAM role
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

# Client CodeDeploy deployment group
resource "aws_codedeploy_deployment_group" "client_codedeploy" {
  app_name               = aws_codedeploy_app.client_codedeploy.name
  deployment_group_name  = "${var.stack}-client"
  service_role_arn       = aws_iam_role.codedeploy_role.arn
  deployment_config_name = aws_codedeploy_deployment_config.client_codedeploy.id

  autoscaling_groups = var.client_asg_names

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}

# Client CodePipeline IAM role
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
      "s3:PutObject"
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
      "codebuild:StartBuild"
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetApplicationRevision",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:RegisterApplicationRevision"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "client_codepipeline_policy" {
  name   = "client_codepipeline_policy"
  role   = aws_iam_role.client_codepipeline_role.id
  policy = data.aws_iam_policy_document.client_codepipeline_policy.json
}

# Client CodePipeline
resource "aws_codepipeline" "client_pipeline" {
  name     = "${var.stack}-client-pipeline"
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
        BranchName       = var.env
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
