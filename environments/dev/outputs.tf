output "api_endpoint" {
  description = "New GATEWAY_API_URL / api_gateway_url for callers to switch to -- append /v1/chat (JWT) or /iam/v1/chat (SigV4)."
  value       = module.api_gateway.api_endpoint
}

output "execute_api_arn_iam_route" {
  value = module.api_gateway.execute_api_arn_iam_route
}

output "access_log_group_name" {
  description = "aws logs tail <this> --follow to watch requests live, including ones the AWS_IAM authorizer rejected."
  value       = module.api_gateway.access_log_group_name
}

output "vpc_link_security_group_id" {
  description = "For bedrock-runtime-gateway-infra's ecs_service ALB security group to allow as ingress (looked up by name there, not referenced directly -- see this file's own module comment)."
  value       = aws_security_group.vpc_link.id
}

output "vpc_link_security_group_name" {
  value = aws_security_group.vpc_link.name
}
