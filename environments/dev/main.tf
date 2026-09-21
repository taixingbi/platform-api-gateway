# Deliberately loosely coupled to bedrock-runtime-gateway: this repo
# never references bedrock-runtime-gateway's Terraform state directly
# (no terraform_remote_state, no hardcoded resource IDs) -- it looks
# up the existing private ALB by name via a plain AWS data source, the
# same way modules/portal_service (in platform-control-plane/infra)
# looks up the AWS-managed CloudFront prefix list by name. Either repo
# can be re-applied independently without the other's state file.
#
# This VPC Link's security group is deliberately named differently
# from the one bedrock-runtime-gateway used to own directly
# (gateway-dev-vpc-link) -- AWS enforces unique security group names
# per VPC, so reusing that exact name here would collide with the one
# still being destroyed on the other side of this split's cutover
# (see the split's own README/commit message for the full sequencing).

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

locals {
  name_prefix = "gateway-dev"
}

data "aws_lb" "gateway" {
  name = "${local.name_prefix}-alb"
}

data "aws_lb_listener" "gateway_http" {
  load_balancer_arn = data.aws_lb.gateway.arn
  port              = 80
}

# Phase 4 (2026-09-21, "direct cutover"): the control-plane backend's
# own ALB (platform-control-plane/infra), looked up by name same as
# gateway's own above.
data "aws_lb" "control_plane_backend" {
  name = "${local.name_prefix}-control-plane-alb"
}

data "aws_lb_listener" "control_plane_backend_http" {
  load_balancer_arn = data.aws_lb.control_plane_backend.arn
  port              = 80
}

resource "aws_security_group" "vpc_link" {
  name        = "${local.name_prefix}-api-gw-vpc-link"
  description = "API Gateway VPC Link ENIs -- egress only, reaches the private ALB"
  vpc_id      = data.aws_lb.gateway.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "dev"
  }
}

module "api_gateway" {
  source = "../../modules/api_gateway"

  name_prefix                = local.name_prefix
  environment                = "dev"
  alb_listener_arn           = data.aws_lb_listener.gateway_http.arn
  admin_alb_listener_arn     = data.aws_lb_listener.control_plane_backend_http.arn
  vpc_link_subnet_ids        = data.aws_lb.gateway.subnets
  vpc_link_security_group_id = aws_security_group.vpc_link.id
  log_group_name             = "/ai-platform/apigateway/platform-api-gateway-dev"
}
