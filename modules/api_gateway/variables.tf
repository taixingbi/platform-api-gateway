variable "name_prefix" {
  description = "Prefix applied to resource names, e.g. \"gateway-dev\"."
  type        = string
}

variable "environment" {
  description = "\"dev\" or \"prod\" -- stamped into the access log's own \"environment\" field (see the stage's access_log_settings.format)."
  type        = string
}

variable "alb_listener_arn" {
  description = "The private ALB listener to integrate with (modules/ecs_service's alb_listener_arn output)."
  type        = string
}

variable "vpc_link_subnet_ids" {
  description = "Subnets for the VPC Link's ENIs. Can be the same public subnets the ALB/ECS tasks use -- the VPC Link itself needs no internet route, only a path to the ALB."
  type        = list(string)
}

variable "vpc_link_security_group_id" {
  description = "Security group attached to the VPC Link's ENIs; must be allowed as ingress on the ALB's security group."
  type        = string
}

variable "principal_arn_header" {
  description = "Header the IAM route overwrites with the verified caller ARN, and the open route strips. Must match services/gateway/auth/aws_iam.py's HEADER_PRINCIPAL_ARN."
  type        = string
  default     = "x-platform-principal-arn"
}

variable "account_id_header" {
  description = "Header the IAM route overwrites with the verified caller's account ID, and the open route strips. Must match services/gateway/auth/aws_iam.py's HEADER_ACCOUNT_ID."
  type        = string
  default     = "x-platform-account-id"
}

variable "log_retention_days" {
  description = "CloudWatch retention for the stage's access log group."
  type        = number
  default     = 14
}

variable "log_group_name" {
  description = "Override for the access log group name; defaults to \"/aws/apigateway/<name_prefix>-api\" when empty."
  type        = string
  default     = ""
}

# Plan section 35's P1 hardening -- edge throttling + WAF (35.11).
# Stage-level throttle is a second, coarser layer above
# TenantPolicy.rpm_limit (bedrock-gateway-app's own per-tenant limit,
# enforced deep in the request pipeline) -- this one protects the
# whole platform from an aggregate burst across every tenant at once,
# before a request even reaches the VPC Link.
variable "throttling_rate_limit" {
  description = "Steady-state requests/second across the whole API (all tenants combined)."
  type        = number
  default     = 200
}

variable "throttling_burst_limit" {
  type    = number
  default = 400
}
