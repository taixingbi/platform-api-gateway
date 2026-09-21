# Mirrors environments/dev -- see that file's own comments for why
# this repo looks up the ALB by name (data source) instead of
# referencing bedrock-runtime-gateway-infra's Terraform state directly.

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
  name_prefix = "gateway-prod"
}

data "aws_lb" "gateway" {
  name = "${local.name_prefix}-alb"
}

data "aws_lb_listener" "gateway_http" {
  load_balancer_arn = data.aws_lb.gateway.arn
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
    Environment = "prod"
  }
}

module "api_gateway" {
  source = "../../modules/api_gateway"

  name_prefix                = local.name_prefix
  environment                = "prod"
  alb_listener_arn           = data.aws_lb_listener.gateway_http.arn
  vpc_link_subnet_ids        = data.aws_lb.gateway.subnets
  vpc_link_security_group_id = aws_security_group.vpc_link.id
  log_group_name             = "/ai-platform/apigateway/platform-api-gateway-prod"
}
