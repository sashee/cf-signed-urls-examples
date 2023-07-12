provider "aws" {
}

resource "random_id" "id" {
  byte_length = 8
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "/tmp/lambda-${random_id.id.hex}.zip"
	source {
    content  = file("index.mjs")
    filename = "index.mjs"
  }
}

resource "aws_lambda_function" "signer" {
  function_name    = "signer-${random_id.id.hex}"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  environment {
    variables = {
			DISTRIBUTION_DOMAIN = aws_cloudfront_distribution.distribution.domain_name
			CF_PRIVATE_KEY_PARAMETER = module.cf_key.parameter_name
			KEYPAIR_ID = aws_cloudfront_public_key.generated_key.id
			KMS_KEY_ID = aws_kms_key.key.arn
			PRIVATE_KEY_CIPHERTEXT = jsondecode(data.local_file.key.content).PrivateKeyCiphertextBlob
			KMS_KEYPAIR_ID = aws_cloudfront_public_key.kms.id
    }
  }
  timeout = 30
  handler = "index.handler"
  runtime = "nodejs18.x"
  role    = aws_iam_role.signer.arn
}

data "aws_iam_policy_document" "signer" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]
  }
  statement {
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
			module.cf_key.parameter_arn
    ]
  }
  statement {
    actions = [
      "kms:Decrypt",
    ]
    resources = [
			aws_kms_key.key.arn
    ]
  }
}

resource "aws_cloudwatch_log_group" "signer" {
  name              = "/aws/lambda/${aws_lambda_function.signer.function_name}"
  retention_in_days = 14
}

resource "aws_iam_role_policy" "signer" {
  role   = aws_iam_role.signer.id
  policy = data.aws_iam_policy_document.signer.json
}

resource "aws_iam_role" "signer" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

# TODO: this could be a function URL when there is a way to remove the cycle
# see: https://github.com/hashicorp/terraform-provider-aws/issues/31405
resource "aws_apigatewayv2_api" "api" {
  name          = "api-${random_id.id.hex}"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "api" {
  api_id           = aws_apigatewayv2_api.api.id
  integration_type = "AWS_PROXY"

  integration_method     = "POST"
  integration_uri        = aws_lambda_function.signer.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "api" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "$default"

  target = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_stage" "api" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.signer.arn
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

