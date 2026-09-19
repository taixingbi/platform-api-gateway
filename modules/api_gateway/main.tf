# Front door for the gateway: one HTTP API, one VPC Link to the private
# ALB (see modules/ecs_service), and two routes that reach the exact
# same backend but differ in who's allowed to call them and what
# identity headers the backend can trust:
#
#   ANY /iam/{proxy+}  AWS_IAM   -- SigV4-signed calls. API Gateway
#                                   verifies the signature itself (this
#                                   module does none of that) and
#                                   overwrites x-platform-principal-arn/
#                                   x-platform-account-id with its own
#                                   verified $context.identity.* values,
#                                   discarding whatever the client sent.
#   ANY /{proxy+}      NONE      -- Bearer JWT calls, verified by the app
#                                   itself exactly as before. The two
#                                   identity headers are stripped here
#                                   (remove, not just "don't set") so a
#                                   client can never inject them on this
#                                   route and impersonate the IAM path.
#
# A single aws_apigatewayv2_route can't carry two different
# authorization_type values, which is why this is two routes (sharing
# one VPC Link and ALB target) rather than one.

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.name_prefix}-vpc-link"
  subnet_ids         = var.vpc_link_subnet_ids
  security_group_ids = [var.vpc_link_security_group_id]
}

locals {
  # $request.path.proxy is the {proxy+} catch-all's value (e.g. a client
  # calling /iam/v1/chat has $request.path.proxy == "v1/chat"); prefixing
  # with "/" gives the backend the same path it would see called
  # directly ("/v1/chat").
  path_rewrite = { "overwrite:path" = "/$${request.path.proxy}" }
}

resource "aws_apigatewayv2_integration" "iam" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_uri        = var.alb_listener_arn
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"

  request_parameters = merge(local.path_rewrite, {
    "overwrite:header.${var.principal_arn_header}" = "$${context.identity.userArn}"
    "overwrite:header.${var.account_id_header}"    = "$${context.identity.accountId}"
    # Same join-key gap the access log's own api_gateway_request_id
    # field exists for (see this stage's format comment) -- gateway-api
    # logs this same value under the same field name (telemetry/
    # middleware.py) so the two logs can be correlated. Writing a header
    # FROM a $context variable this way is the supported direction;
    # $context.requestHeader.* (reading an INBOUND header, the reverse)
    # is confirmed NOT supported for the stage's access log format, a
    # different mechanism entirely -- this one already works for
    # principal_arn_header/account_id_header above.
    #
    # x- prefixed like every other custom header here, NOT the bare
    # "apigw-requestid" name -- confirmed live that AWS reserves that
    # exact name ("Operations on header apigw-requestid are
    # restricted", 400 on both read AND write attempts), presumably
    # because it's used internally by some integration types even
    # though nothing reaches this VPC Link/HTTP_PROXY integration with
    # it pre-set.
    "overwrite:header.x-apigw-request-id" = "$${context.requestId}"
  })
}

resource "aws_apigatewayv2_integration" "open" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_uri        = var.alb_listener_arn
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"

  # Empty string is API Gateway's documented "remove this header"
  # value -- not "don't set", but "strip it if the client sent it".
  # This is the control that makes the IAM route's header-trust safe:
  # without it, a client could set x-platform-principal-arn directly on
  # this open route and the app would trust it.
  request_parameters = merge(local.path_rewrite, {
    "remove:header.${var.principal_arn_header}" = ""
    "remove:header.${var.account_id_header}"    = ""
    # Overwrite (not remove-if-client-sent, like the two above) -- this
    # isn't a trust/auth field, just a log correlation convenience, but
    # still shouldn't let a client inject an arbitrary value that looks
    # like it came from API Gateway. See the iam integration's identical
    # mapping for the full comment.
    "overwrite:header.x-apigw-request-id" = "$${context.requestId}"
  })
}

resource "aws_apigatewayv2_route" "iam" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY /iam/{proxy+}"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.iam.id}"
}

resource "aws_apigatewayv2_route" "open" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY /{proxy+}"
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.open.id}"
}


# Access logging -- covers every request that reaches this stage,
# including ones the AWS_IAM authorizer rejects before the backend
# ever sees them (the one class of failure gateway-api's own
# CloudWatch logs can never show, since a rejected request never
# reaches it).
resource "aws_cloudwatch_log_group" "access" {
  name              = var.log_group_name != "" ? var.log_group_name : "/aws/apigateway/${var.name_prefix}-api"
  retention_in_days = var.log_retention_days
}

# HTTP APIs (apigatewayv2), unlike REST APIs, don't use the account-
# level CloudWatchRoleArn setting for log delivery -- the destination
# log group's own resource policy is what has to grant apigateway.
# amazonaws.com write access.
data "aws_iam_policy_document" "access_log_delivery" {
  statement {
    sid    = "ApiGatewayAccessLogDelivery"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.access.arn}:*"]
  }
}

resource "aws_cloudwatch_log_resource_policy" "access_log_delivery" {
  policy_name     = "${var.name_prefix}-api-gw-access-log"
  policy_document = data.aws_iam_policy_document.access_log_delivery.json
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # Plan section 35.11 -- aggregate, platform-wide throttle, coarser
  # and separate from TenantPolicy.rpm_limit (bedrock-gateway-app's own
  # per-tenant limit, enforced deep in the request pipeline). This one
  # protects the whole platform from a burst across every tenant
  # combined, before a request even reaches the VPC Link.
  default_route_settings {
    throttling_rate_limit  = var.throttling_rate_limit
    throttling_burst_limit = var.throttling_burst_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    # A plain string template, not jsonencode() -- $context.* fields are
    # interpolated by API Gateway at request time, not by Terraform, and
    # every value here is a string, so jsonencode() would infer this as
    # map(string) (maps have no defined order) and alphabetize the keys
    # instead of preserving the grouping below. A literal string sidesteps
    # that entirely.
    # service/environment are fixed per-deployment identity fields, same
    # convention as bedrock-gateway-app's/platform-authz-service's own
    # structured JSON logs (telemetry/logging.py) -- let a request be
    # traced across every log source without needing to already know
    # which log group it came from.
    #
    # api_gateway_request_id is API Gateway's OWN internal request ID
    # (always an opaque string like "D0V2kjWCIAMEJmw=") -- distinct from
    # our own application-level request_id, hence the explicit name
    # (was "requestId", easy to mistake for the app's own field of the
    # same generic name once both show up side by side in a log
    # aggregator). Exposing an arbitrary inbound request header (e.g.
    # the caller's x-request-id, traceparent, or x-session-id) here was
    # tried and confirmed NOT supported -- API Gateway v2 access logs
    # only accept a fixed set of $context variables;
    # $context.requestHeader.* 400s the stage update ("context
    # variables are not supported"), so this log can never carry
    # trace_id/span_id/session_id/the app's request_id. Correlation has
    # to go the other way instead: the iam/open integrations map
    # $context.requestId onto x-apigw-request-id (the bare name
    # "apigw-requestid" is AWS-reserved -- confirmed live, 400s any
    # mapping operation at all), which gateway-api logs under this same
    # field name alongside its own request_id.
    format = chomp(<<-EOT
      {"requestTime":"$context.requestTime","service":"platform-api-gateway","environment":"${var.environment}","api_gateway_request_id":"$context.requestId","ip":"$context.identity.sourceIp","httpMethod":"$context.httpMethod","routeKey":"$context.routeKey","protocol":"$context.protocol","integrationStatus":"$context.integration.status","integrationError":"$context.integration.error","authorizerError":"$context.authorizer.error","errorMessage":"$context.error.message","status":"$context.status","responseLength":"$context.responseLength"}
    EOT
    )
  }

  depends_on = [aws_cloudwatch_log_resource_policy.access_log_delivery]
}

# --- WAF (plan section 35.11, P1 production hardening) --------------------
#
# Real recurring cost -- see var.enable_waf's own comment. Regional
# scope (this is an API Gateway stage, not CloudFront) -- confirmed
# via the AWS provider's own resource support (aws_wafv2_web_acl_
# association accepts an API Gateway v2 stage ARN as resource_arn).
#
# Three rule groups, priority order matters (lower evaluated first):
#   1. AWS Managed Core Rule Set -- generic web exploit protection
#      (SQLi, XSS, path traversal, etc.) -- most requests never
#      trigger the more specific rules below, so this goes first.
#   2. AWS Managed Known Bad Inputs -- exploit patterns tied to known
#      CVEs, log4j-style payloads.
#   3. A rate-based rule, per-IP over a 5-minute window -- the
#      per-source backstop var.waf_rate_limit_per_5min describes; the
#      stage's own throttling_rate_limit above is aggregate across
#      every source, this one catches a single bad actor specifically.
resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0
  name  = "${var.name_prefix}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-managed-core-rule-set"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-core-rule-set"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-managed-known-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "per-ip-rate-limit"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-per-ip-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_apigatewayv2_stage.default.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
