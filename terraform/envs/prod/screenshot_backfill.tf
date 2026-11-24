variable "screenshot_backfill_zip_path" {
  type        = string
  default     = "../../../../trophyquest-igdb/out/screenshot-backfill.zip"
  description = "Path to the backfill ZIP, relative to the prod Terraform directory or absolute."
}

variable "screenshot_backfill_twitch_secret_arn" {
  type        = string
  default     = null
  description = "Existing Twitch secret ARN, or null to provision a dedicated secret."
}

locals {
  screenshot_backfill_name = "trophyquest-igdb-screenshot-backfill"
  screenshot_backfill_zip  = abspath(var.screenshot_backfill_zip_path)
  backfill_twitch_secret   = var.screenshot_backfill_twitch_secret_arn == null ? aws_secretsmanager_secret.screenshot_backfill_twitch[0].arn : var.screenshot_backfill_twitch_secret_arn
}

resource "aws_s3_object" "screenshot_backfill" {
  bucket       = data.aws_s3_bucket.artifacts.id
  key          = "lambda/${local.screenshot_backfill_name}/${filesha256(local.screenshot_backfill_zip)}.zip"
  source       = local.screenshot_backfill_zip
  source_hash  = filebase64sha256(local.screenshot_backfill_zip)
  content_type = "application/zip"
}

resource "aws_secretsmanager_secret" "screenshot_backfill_postgres" {
  name = "${var.project_name}/${var.environment}/screenshot-backfill/postgres"
}

resource "aws_secretsmanager_secret" "screenshot_backfill_twitch" {
  count = var.screenshot_backfill_twitch_secret_arn == null ? 1 : 0
  name  = "${var.project_name}/${var.environment}/screenshot-backfill/twitch"
}

resource "aws_cloudwatch_log_group" "screenshot_backfill" {
  name = "/aws/lambda/${local.screenshot_backfill_name}"
}

resource "aws_iam_role" "screenshot_backfill" {
  name = "tq-lambda-screenshot-backfill-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "screenshot_backfill" {
  name = "screenshot-backfill-execution"
  role = aws_iam_role.screenshot_backfill.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.screenshot_backfill.arn}:log-stream:*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = [aws_secretsmanager_secret.screenshot_backfill_postgres.arn, local.backfill_twitch_secret]
      }
    ]
  })
}

resource "aws_lambda_function" "screenshot_backfill" {
  function_name    = local.screenshot_backfill_name
  role             = aws_iam_role.screenshot_backfill.arn
  handler          = "igdb_enricher.screenshot_backfill_handler.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 120
  publish          = true
  s3_bucket        = aws_s3_object.screenshot_backfill.bucket
  s3_key           = aws_s3_object.screenshot_backfill.key
  source_code_hash = aws_s3_object.screenshot_backfill.source_hash

  environment {
    variables = {
      POSTGRES_SECRET_ARN = aws_secretsmanager_secret.screenshot_backfill_postgres.arn
      TWITCH_SECRET_ARN   = local.backfill_twitch_secret
    }
  }

  depends_on = [aws_iam_role_policy.screenshot_backfill]
}

resource "aws_lambda_alias" "screenshot_backfill_prod" {
  name             = "prod"
  function_name    = aws_lambda_function.screenshot_backfill.function_name
  function_version = aws_lambda_function.screenshot_backfill.version
}

resource "aws_iam_policy" "screenshot_backfill_invoke" {
  name = "tq-invoke-screenshot-backfill-prod"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_alias.screenshot_backfill_prod.arn
    }]
  })
}

resource "aws_iam_role" "screenshot_backfill_operator" {
  name = "tq-screenshot-backfill-operator-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/trophyquest-admin" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "screenshot_backfill_operator" {
  role       = aws_iam_role.screenshot_backfill_operator.name
  policy_arn = aws_iam_policy.screenshot_backfill_invoke.arn
}

output "screenshot_backfill_operator_role_arn" {
  value = aws_iam_role.screenshot_backfill_operator.arn
}

output "screenshot_backfill_alias_arn" {
  value = aws_lambda_alias.screenshot_backfill_prod.arn
}

output "screenshot_backfill_invoke_policy_arn" {
  value = aws_iam_policy.screenshot_backfill_invoke.arn
}

output "screenshot_backfill_postgres_secret_arn" {
  value = aws_secretsmanager_secret.screenshot_backfill_postgres.arn
}

output "screenshot_backfill_twitch_secret_arn" {
  value = local.backfill_twitch_secret
}
