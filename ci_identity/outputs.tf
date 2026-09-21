output "role_arns" {
  description = "Set as AWS_API_GATEWAY_PLAN_ROLE_ARN / AWS_API_GATEWAY_APPLY_DEV_ROLE_ARN / AWS_API_GATEWAY_APPLY_PROD_ROLE_ARN in this repo's own GitHub Environment variables -- unchanged from before this migration."
  value       = module.github_oidc.role_arns
}
