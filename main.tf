provider "aws" {
  version = "~> 2.0"
  region  = var.region
}

variable "region" {
  default = "us-east-1"
}

resource "aws_sqs_queue" "queue" {
  name                      = "apigateway-queue"
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 86400
  receive_wait_time_seconds = 10
}

resource "aws_iam_role" "apiSQS" {
  name = "apigateway_sqs"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "api_policy" {
  name = "api-sqs-cloudwatch-policy"

  policy = templatefile("policies/api-gateway-permission.json", {
    sqs_arn = aws_sqs_queue.queue.arn
  })
}

resource "aws_iam_role_policy_attachment" "api_exec_role" {
  role       = aws_iam_role.apiSQS.name
  policy_arn = aws_iam_policy.api_policy.arn
}

resource "aws_iam_policy" "lambda_sqs_policy" {
  name        = "lambda_policy_db"
  description = "IAM policy for lambda Being invoked by SQS"

  policy = templatefile("policies/lambda-permission.json", {
    sqs_arn = aws_sqs_queue.queue.arn
  })
}

resource "aws_iam_role" "lambda_exec_role" {
  name               = "lambda-lambda-db"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "lambda_role_policy" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_sqs_policy.arn
}

resource "aws_api_gateway_rest_api" "apiGateway" {
  name        = "api-gateway-SQS"
  description = "POST records to SQS queue"
}

resource "aws_api_gateway_resource" "form_score" {
  rest_api_id = aws_api_gateway_rest_api.apiGateway.id
  parent_id   = aws_api_gateway_rest_api.apiGateway.root_resource_id
  path_part   = "form-score"
}

resource "aws_api_gateway_request_validator" "validator_query" {
  name                        = "queryValidator"
  rest_api_id                 = aws_api_gateway_rest_api.apiGateway.id
  validate_request_body       = false
  validate_request_parameters = true
}

resource "aws_api_gateway_method" "method_form_score" {
  rest_api_id   = aws_api_gateway_rest_api.apiGateway.id
  resource_id   = aws_api_gateway_resource.form_score.id
  http_method   = "POST"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy"        = false,
    "method.request.querystring.unity" = true
  }

  request_validator_id = aws_api_gateway_request_validator.validator_query.id
}

resource "aws_api_gateway_integration" "sqs_integration" {
  rest_api_id             = aws_api_gateway_rest_api.apiGateway.id
  resource_id             = aws_api_gateway_resource.form_score.id
  http_method             = aws_api_gateway_method.method_form_score.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  credentials             = aws_iam_role.apiSQS.arn
  uri                     = "arn:aws:apigateway:${var.region}:sqs:path/${aws_sqs_queue.queue.name}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = <<EOF
Action=SendMessage&MessageBody={
  "method": "$context.httpMethod",
  "body-json" : $input.json('$'),
  "queryParams": {
    #foreach($param in $input.params().querystring.keySet())
    "$param": "$util.escapeJavaScript($input.params().querystring.get($param))" #if($foreach.hasNext),#end
  #end
  },
  "pathParams": {
    #foreach($param in $input.params().path.keySet())
    "$param": "$util.escapeJavaScript($input.params().path.get($param))" #if($foreach.hasNext),#end
    #end
  }
}"
EOF
  }

  depends_on = [
    aws_iam_role_policy_attachment.api_exec_role
  ]
}

resource "aws_api_gateway_method_response" "http200" {
  rest_api_id = aws_api_gateway_rest_api.apiGateway.id
  resource_id = aws_api_gateway_resource.form_score.id
  http_method = aws_api_gateway_method.method_form_score.http_method
  status_code = 200
}

resource "aws_api_gateway_integration_response" "http200" {
  rest_api_id       = aws_api_gateway_rest_api.apiGateway.id
  resource_id       = aws_api_gateway_resource.form_score.id
  http_method       = aws_api_gateway_method.method_form_score.http_method
  status_code       = aws_api_gateway_method_response.http200.status_code
  selection_pattern = "^2[0-9][0-9]"
}

resource "aws_api_gateway_deployment" "api" {
  rest_api_id = aws_api_gateway_rest_api.apiGateway.id
  stage_name  = "prod"

  depends_on = [
    aws_api_gateway_integration.sqs_integration
  ]

  triggers = {
    redeployment = sha1(join(",", tolist([
      jsonencode(aws_api_gateway_integration.sqs_integration)
    ])))
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "archive_file" "lambda_with_dependencies" {
  source_dir  = "lambda/"
  output_path = "lambda.zip"
  type        = "zip"
}

resource "aws_lambda_function" "lambda_sqs" {
  function_name    = "lambda_sqs"
  handler          = "handler.lambda_handler"
  role             = aws_iam_role.lambda_exec_role.arn
  runtime          = "python3.8"
  filename         = data.archive_file.lambda_with_dependencies.output_path
  source_code_hash = data.archive_file.lambda_with_dependencies.output_base64sha256
  timeout          = 30
  memory_size      = 128

  depends_on = [
    aws_iam_role_policy_attachment.lambda_role_policy
  ]
}

resource "aws_lambda_permission" "allows_sqs_to_trigger_lambda" {
  statement_id  = "AllowExecutionFromSQS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_sqs.function_name
  principal     = "sqs.amazonaws.com"
  source_arn    = aws_sqs_queue.queue.arn
}

resource "aws_lambda_event_source_mapping" "event_source_mapping" {
  batch_size       = 1
  event_source_arn = aws_sqs_queue.queue.arn
  enabled          = true
  function_name    = aws_lambda_function.lambda_sqs.arn
}
