# This repo's own CI identity (infra plan/apply-dev/apply-prod) --
# Terraform-ownership migration from platform-foundation
# (2026-09-21), step 3 of 6. These 3 IAM roles already existed,
# created and managed by platform-foundation/environments/global's
# module "github_oidc_api_gateway" call. Moved here via `terraform
# import` (never delete/recreate) so this repo owns its own CI
# permissions going forward. ARNs are unchanged; this repo's GitHub
# Environment variables do not need to change.
#
# A separate Terraform root from environments/dev -- own state file,
# own (infrequent) apply.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Terraform-ownership migration follow-up: needed now for
# ManageApiGatewayRoles' resource ARN (this repo's Terraform never
# touched IAM at all before ci_identity moved in).
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# This repo's own Terraform plan/apply-dev/apply-prod roles -- it's
# Terraform doing plan+apply, not a Docker build+deploy repo like
# app/portal/authz. Scoped to exactly what modules/api_gateway (this
# repo) touches: EC2 (its own VPC Link security group), ELB read-only
# (looks up the existing ALB/listener by name, doesn't manage it), and
# API Gateway v2 itself.
data "aws_iam_policy_document" "api_gateway_plan" {
  statement {
    sid = "ReadOnly"
    actions = [
      "ec2:Describe*",
      "elasticloadbalancing:Describe*",
      "apigateway:GET",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
  statement {
    # Added for the module's access_log_settings CloudWatch log group +
    # resource policy (the plan/apply-dev roles predate that resource,
    # so a plan against it 403s with AccessDeniedException on
    # logs:DescribeLogGroups otherwise).
    sid = "LogsReadOnly"
    actions = [
      "logs:Describe*",
      "logs:List*",
      "logs:GetLogGroupFields",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "TerraformStateS3"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*"]
  }
  # WAF-on-HTTP-API was tried and reverted (AWS WAFv2 doesn't support
  # API Gateway HTTP APIs -- see modules/api_gateway/main.tf's own
  # comment) but the plan role never got a wafv2 grant at all (only
  # apply-dev/apply-prod did, via WafBroad below), so a plan can't even
  # refresh the one Web ACL that got created before the association
  # failed -- 403 on wafv2:GetWebACL, blocking the plan step that would
  # otherwise destroy it cleanly. Read-only, matching this document's
  # own ReadOnly-statement style.
  statement {
    sid       = "WafReadOnly"
    actions   = ["wafv2:Get*", "wafv2:List*"]
    resources = ["*"]
  }
  # Terraform-ownership migration follow-up: this repo's Terraform
  # never touched IAM at all before ci_identity moved in (no
  # execution/task roles of its own, just VPC Link SG + API Gateway
  # resources) -- needed now to refresh ci_identity's own aws_iam_role
  # resources and read the account-wide OIDC provider via data source.
  statement {
    sid       = "IamReadOnly"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "api_gateway_apply" {
  statement {
    sid       = "Ec2Broad"
    actions   = ["ec2:*"]
    resources = ["*"]
  }
  statement {
    sid       = "ElbReadOnly"
    actions   = ["elasticloadbalancing:Describe*"]
    resources = ["*"]
  }
  statement {
    sid       = "ApiGatewayBroad"
    actions   = ["apigateway:*"]
    resources = ["*"]
  }
  statement {
    # Added for the module's access_log_settings CloudWatch log group +
    # resource policy (see api_gateway_plan's LogsReadOnly comment --
    # apply needs to create/update/delete both, not just read them).
    sid       = "LogsBroad"
    actions   = ["logs:*"]
    resources = ["*"]
  }
  statement {
    sid = "TerraformStateS3"
    # S3-native state locking (use_lockfile) -- DeleteObject releases
    # the <key>.tflock object an apply creates to hold the lock. Not
    # needed by the plan role above -- every plan job always runs with
    # -lock=false, so it never touches the lock file at all.
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*"]
  }
  # The WAF Web ACL + its association with the API Gateway stage. Web
  # ACL ids don't exist until creation, same "*" reasoning as every
  # other broad grant here.
  statement {
    sid       = "WafBroad"
    actions   = ["wafv2:*"]
    resources = ["*"]
  }
  # Terraform-ownership migration follow-up: this repo's Terraform
  # never managed any IAM role before ci_identity moved in -- this
  # repo's own CI roles (gha-api-gateway-*, managed by this same
  # ci_identity root, including itself) are the first.
  statement {
    sid = "ManageApiGatewayRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies", "iam:TagRole", "iam:UntagRole", "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/gha-api-gateway-*"]
  }
  statement {
    sid       = "OidcProviderReadOnly"
    actions   = ["iam:ListOpenIDConnectProviders", "iam:GetOpenIDConnectProvider"]
    resources = ["*"]
  }
}

module "github_oidc" {
  source = "git::https://github.com/taixingbi/platform-foundation.git//modules/github_oidc?ref=main"

  # The account-wide OIDC provider is owned by platform-foundation
  # (formally imported into its state) -- every other repo, this one
  # included, only ever references it via data source.
  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = "platform-edge-gateway"

  roles = {
    plan = {
      role_name   = "gha-api-gateway-plan"
      policy_json = data.aws_iam_policy_document.api_gateway_plan.json
    }
    apply-dev = {
      role_name   = "gha-api-gateway-apply-dev"
      policy_json = data.aws_iam_policy_document.api_gateway_apply.json
    }
    apply-prod = {
      role_name   = "gha-api-gateway-apply-prod"
      policy_json = data.aws_iam_policy_document.api_gateway_apply.json
    }
  }
}
