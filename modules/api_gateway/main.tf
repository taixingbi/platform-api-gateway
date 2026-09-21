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

  # SECURITY FIX (2026-09-21, live-caught): empty string is API
  # Gateway's DOCUMENTED "remove this header" value for a
  # `remove:header.*` mapping -- but confirmed live, via both
  # Terraform apply and a direct `aws apigatewayv2 update-integration`
  # call, that this specific API silently DROPS any request_parameters
  # entry whose value is an empty string, for every action type
  # (remove: AND overwrite:), not just this one. The write appears to
  # succeed (no error, "Apply complete") but the mapping is simply
  # never persisted -- confirmed exploitable: a real, unauthenticated
  # curl request with x-platform-principal-arn set was accepted and
  # dispatched into the AWS_IAM auth path (pipeline.py's authenticate()
  # takes that path whenever the header is present at all, regardless
  # of which route delivered it).
  #
  # Fix: overwrite (not remove) to a fixed sentinel that can never
  # collide with a real IAM principal ARN or account ID, using the
  # SAME overwrite: action already proven to persist correctly
  # (x-apigw-request-id below has worked the whole time -- only empty
  # string values are silently dropped, not the overwrite: action
  # itself). pipeline.py's authenticate() still takes the IAM path for
  # this sentinel (the header is still truthy), but
  # iam_tenant_resolver.resolve() then fails with a clean "no tenant
  # mapping" 403 for it, same as any other unmapped principal --
  # impersonation of a REAL principal is exactly as impossible as
  # actually removing the header would have been, just via a different
  # mechanism forced by this platform limitation.
  request_parameters = merge(local.path_rewrite, {
    "overwrite:header.${var.principal_arn_header}" = "not-authenticated-via-api-gateway-iam-route"
    "overwrite:header.${var.account_id_header}"    = "not-authenticated-via-api-gateway-iam-route"
    "overwrite:header.x-apigw-request-id"          = "$${context.requestId}"
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

# Phase 4 (2026-09-21, "direct cutover"): admin/onboarding traffic now
# goes to platform-control-plane's own backend instead of falling
# through to the "open" route/gateway-api above -- a specific path
# always wins over {proxy+} in API Gateway v2's route resolution, so
# this doesn't touch the open route or anything it still serves
# (chat/jobs/everything else). Same NONE auth + header-overwrite
# security control as "open" (this is still a JWT-authenticated route,
# a client could still try to inject the identity headers here) --
# see the open integration's own comment for why this overwrites to a
# sentinel instead of removing the header (a real, live-confirmed API
# Gateway limitation: empty-string request_parameters values are
# silently dropped, not persisted at all).
resource "aws_apigatewayv2_integration" "admin" {
  count = var.admin_alb_listener_arn != null ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_uri        = var.admin_alb_listener_arn
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"

  # Unlike local.path_rewrite (which re-derives the FULL original path
  # from {proxy+}, since the catch-all route's fixed prefix is just
  # "/"), this route's fixed prefix ("/v1/admin/") is NOT included in
  # $request.path.proxy -- calling /v1/admin/tenants gives proxy ==
  # "tenants", not "v1/admin/tenants". The backend's own routes are
  # registered at the full /v1/admin/* path (see admin_routes.py/
  # onboarding_routes.py), so the prefix has to be re-prepended here,
  # not just re-derived.
  request_parameters = {
    "overwrite:path"                               = "/v1/admin/$${request.path.proxy}"
    "overwrite:header.${var.principal_arn_header}" = "not-authenticated-via-api-gateway-iam-route"
    "overwrite:header.${var.account_id_header}"    = "not-authenticated-via-api-gateway-iam-route"
    "overwrite:header.x-apigw-request-id"          = "$${context.requestId}"
  }
}

resource "aws_apigatewayv2_route" "admin" {
  count = var.admin_alb_listener_arn != null ? 1 : 0

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "ANY /v1/admin/{proxy+}"
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.admin[0].id}"
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
  # and separate from TenantPolicy.rpm_limit (bedrock-runtime-gateway-app's own
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
    # convention as bedrock-runtime-gateway-app's/platform-authz-service's own
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
# NOT built, on purpose -- this was attempted (aws_wafv2_web_acl +
# aws_wafv2_web_acl_association against aws_apigatewayv2_stage.default's
# ARN) and failed live: AWS WAFv2's AssociateWebACL only supports
# Amazon API Gateway REST APIs, ALB, AppSync, Cognito user pools, App
# Runner, Verified Access, Amplify, and Bedrock AgentCore Gateway --
# NOT API Gateway HTTP APIs (aws_apigatewayv2_api, what this module
# builds). Confirmed against AWS's own AssociateWebACL API reference,
# not guessed at; the Terraform provider accepts any string ARN
# without validating resource type, so this only surfaces as a
# WAFInvalidParameterException at apply time, not at plan/validate.
#
# The only real way to put AWS WAF in front of this HTTP API is a
# CloudFront distribution (CLOUDFRONT-scope WAF, global not REGIONAL)
# with this API Gateway stage as its origin -- which needs its own
# TLS chain and is naturally the same piece of work as the custom API
# domain (also not built, blocked on the user providing a real
# domain/Route53 zone). Deferred together, not attempted separately.
#
# The stage-level throttling above (default_route_settings) is real,
# live, aggregate edge protection independent of this -- that part of
# 35.11 stands on its own and needed no WAF.
