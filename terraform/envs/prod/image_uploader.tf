data "aws_caller_identity" "current" {}

data "aws_s3_bucket" "images" {
  bucket = "trophyquest-images"
}

data "aws_s3_bucket" "artifacts" {
  bucket = "trophyquest-artifacts"
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  image_uploader_name = "trophyquest-image-uploader"
  image_uploader_arn  = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.image_uploader_name}"
  image_uploader_zip  = abspath(var.image_uploader_zip_path)
  image_prefixes      = ["psn-player", "psn-suite", "psn-trophy", "igdb-cover", "igdb-background", "igdb-screenshot"]
}

resource "aws_s3_object" "image_uploader_bootstrap" {
  bucket       = data.aws_s3_bucket.artifacts.id
  key          = "lambda/${local.image_uploader_name}/${filesha256(local.image_uploader_zip)}.zip"
  source       = local.image_uploader_zip
  source_hash  = filebase64sha256(local.image_uploader_zip)
  content_type = "application/zip"
}

resource "aws_secretsmanager_secret" "image_uploader_postgres" {
  name = "${var.project_name}/${var.environment}/image-uploader/postgres"
}

import {
  to = aws_cloudwatch_log_group.image_uploader
  id = "/aws/lambda/trophyquest-image-uploader"
}

resource "aws_cloudwatch_log_group" "image_uploader" {
  name = "/aws/lambda/${local.image_uploader_name}"
}

import {
  to = aws_iam_role.image_uploader
  id = "tq-lambda-image-uploader-role"
}

resource "aws_iam_role" "image_uploader" {
  name        = "tq-lambda-image-uploader-role"
  description = "Allows Image Uploader function to create logs in CloudWatch and write into S3"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "image_uploader" {
  name = "image-uploader-execution"
  role = aws_iam_role.image_uploader.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.image_uploader.arn}:log-stream:*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = [for prefix in local.image_prefixes : "${data.aws_s3_bucket.images.arn}/${prefix}/*"]
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.image_uploader_postgres.arn
      }
    ]
  })
}

import {
  to = aws_iam_role_policy_attachments_exclusive.image_uploader
  id = "tq-lambda-image-uploader-role"
}

resource "aws_iam_role_policy_attachments_exclusive" "image_uploader" {
  role_name   = aws_iam_role.image_uploader.name
  policy_arns = []

  depends_on = [aws_iam_role_policy.image_uploader]
}

resource "aws_lambda_function" "image_uploader" {
  function_name    = local.image_uploader_name
  role             = aws_iam_role.image_uploader.arn
  handler          = "image_uploader.handler.image_uploader_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 300
  publish          = true
  s3_bucket        = aws_s3_object.image_uploader_bootstrap.bucket
  s3_key           = aws_s3_object.image_uploader_bootstrap.key
  source_code_hash = aws_s3_object.image_uploader_bootstrap.source_hash

  environment {
    variables = {
      IMAGES_BUCKET_NAME  = data.aws_s3_bucket.images.id
      IMAGES_MAX_WORKERS  = "4"
      POSTGRES_SECRET_ARN = aws_secretsmanager_secret.image_uploader_postgres.arn
    }
  }

  lifecycle {
    # The release workflow owns subsequent code updates.
    ignore_changes = [s3_bucket, s3_key, source_code_hash]
  }

  depends_on = [aws_iam_role_policy_attachments_exclusive.image_uploader]
}

resource "aws_lambda_alias" "image_uploader_prod" {
  name             = "prod"
  function_name    = aws_lambda_function.image_uploader.function_name
  function_version = aws_lambda_function.image_uploader.version

  lifecycle {
    # GitHub Actions promotes each release after the version becomes active.
    ignore_changes = [function_version]
  }
}

import {
  to = aws_iam_role.image_uploader_scheduler
  id = "tq-schedule-image-uploader-role"
}

resource "aws_iam_role" "image_uploader_scheduler" {
  name        = "tq-schedule-image-uploader-role"
  description = "Role for the Image Uploader Schedule"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          "aws:SourceArn"     = "arn:aws:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule-group/default"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "image_uploader_scheduler" {
  name = "image-uploader-scheduler"
  role = aws_iam_role.image_uploader_scheduler.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_alias.image_uploader_prod.arn
    }]
  })
}

import {
  to = aws_iam_role_policy_attachments_exclusive.image_uploader_scheduler
  id = "tq-schedule-image-uploader-role"
}

resource "aws_iam_role_policy_attachments_exclusive" "image_uploader_scheduler" {
  role_name   = aws_iam_role.image_uploader_scheduler.name
  policy_arns = []

  depends_on = [aws_iam_role_policy.image_uploader_scheduler]
}

resource "aws_scheduler_schedule" "image_uploader" {
  name                = "${local.image_uploader_name}-schedule"
  group_name          = "default"
  state               = "DISABLED"
  schedule_expression = "rate(15 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_alias.image_uploader_prod.arn
    role_arn = aws_iam_role.image_uploader_scheduler.arn
    input = jsonencode({
      player_avatar_limit      = 5
      trophy_suite_image_limit = 5
      trophy_icon_limit        = 5
      igdb_image_limit         = 5
    })
  }

  depends_on = [aws_iam_role_policy_attachments_exclusive.image_uploader_scheduler]
}

resource "aws_iam_role" "image_uploader_deploy" {
  name = "tq-github-image-uploader-deploy-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            "repo:qsebille/trophyquest-images:environment:prod",
            "repo:qsebille@26115359/trophyquest-images@1414392423:environment:prod"
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "image_uploader_deploy" {
  name = "image-uploader-deploy"
  role = aws_iam_role.image_uploader_deploy.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:PublishVersion"]
        Resource = local.image_uploader_arn
      },
      {
        Effect   = "Allow"
        Action   = "lambda:GetFunctionConfiguration"
        Resource = [local.image_uploader_arn, "${local.image_uploader_arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = "lambda:UpdateAlias"
        Resource = [local.image_uploader_arn, "${local.image_uploader_arn}:prod"]
      }
    ]
  })
}
