# Security groups and DNS Firewall for bot egress control.
#
# Threat model: bots run arbitrary user code. They must ONLY be able to:
#   1. Connect to the game container (websocket on port 8080)
#   2. Call whitelisted LLM APIs (OpenAI, Anthropic, etc.)
#   3. Resolve DNS for allowed domains only
#
# Everything else is blocked.
#
# Three roles:
#   - Dashboard (games_server): orchestrates games, serves web UI
#   - Game containers: run individual game instances, serve websockets
#   - Bot containers: untrusted user code, heavily restricted

# =============================================================================
# Dashboard / Orchestrator (games_server on EC2)
# =============================================================================

resource "aws_security_group" "dashboard" {
  name        = "${var.project_name}-dashboard"
  description = "Dashboard - web UI, orchestrates game and bot containers"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-dashboard-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "dashboard_http" {
  security_group_id = aws_security_group.dashboard.id
  description       = "Dashboard web UI"
  from_port         = var.dashboard_port
  to_port           = var.dashboard_port
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "dashboard_ssh" {
  security_group_id = aws_security_group.dashboard.id
  description       = "SSH - Phase 2: lock to admin CIDR or replace with SSM"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "dashboard_all" {
  security_group_id = aws_security_group.dashboard.id
  description       = "Orchestrator needs outbound to manage ECS tasks, pull images, etc."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# =============================================================================
# Game Containers (ECS Fargate, public subnet)
# Each task gets its own ENI/IP. All listen on port 8080.
# Browsers connect directly for spectating/playing.
# =============================================================================

resource "aws_security_group" "game_container" {
  name        = "${var.project_name}-game-container"
  description = "Game containers - websocket for spectators and bots"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-game-container-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "game_container_public" {
  security_group_id = aws_security_group.game_container.id
  description       = "Spectators and human players connect via browser"
  from_port         = var.game_container_port
  to_port           = var.game_container_port
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- PHASE 2: HTTPS/WSS ---
# Replace public ingress on 8080 with ALB on 443. ALB terminates TLS,
# forwards to game containers on 8080 via target group. Gives wss://
# for free and removes direct public IP exposure.
# Requires: ACM certificate, Route 53 DNS record, ALB in public subnet.

resource "aws_vpc_security_group_ingress_rule" "game_container_from_bot" {
  security_group_id            = aws_security_group.game_container.id
  description                  = "Bots connect to their assigned game"
  from_port                    = var.game_container_port
  to_port                      = var.game_container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bot.id
}

resource "aws_vpc_security_group_egress_rule" "game_container_all" {
  security_group_id = aws_security_group.game_container.id
  description       = "Game containers need outbound for health checks, replay uploads"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# =============================================================================
# Bot Containers (ECS Fargate, private subnet)
# Untrusted user code. No public IP. Heavily restricted egress.
# =============================================================================

resource "aws_security_group" "bot" {
  name        = "${var.project_name}-bot"
  description = "Bot containers - untrusted code, restricted egress only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-bot-sg" }
}

resource "aws_vpc_security_group_egress_rule" "bot_to_game" {
  security_group_id            = aws_security_group.bot.id
  description                  = "Connect to assigned game container"
  from_port                    = var.game_container_port
  to_port                      = var.game_container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.game_container.id
}

resource "aws_vpc_security_group_egress_rule" "bot_https" {
  security_group_id = aws_security_group.bot.id
  description       = "HTTPS to LLM APIs (DNS Firewall restricts actual destinations)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "bot_dns_udp" {
  security_group_id = aws_security_group.bot.id
  description       = "DNS resolution via VPC resolver"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  cidr_ipv4         = "${cidrhost(var.vpc_cidr, 2)}/32"
}

resource "aws_vpc_security_group_egress_rule" "bot_dns_tcp" {
  security_group_id = aws_security_group.bot.id
  description       = "DNS over TCP fallback"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
  cidr_ipv4         = "${cidrhost(var.vpc_cidr, 2)}/32"
}

# =============================================================================
# Route 53 DNS Firewall
# Default-deny DNS resolution. Only domains in the allowlist resolve.
# This prevents bots from reaching arbitrary internet services.
# Applied at VPC level — no sidecar or agent needed.
# =============================================================================

resource "aws_route53_resolver_firewall_domain_list" "allowed" {
  name    = "${var.project_name}-allowed-domains"
  domains = var.llm_api_domains
}

resource "aws_route53_resolver_firewall_domain_list" "block_all" {
  name    = "${var.project_name}-block-all"
  domains = ["*"]
}

resource "aws_route53_resolver_firewall_rule_group" "bot_egress" {
  name = "${var.project_name}-bot-egress"
}

resource "aws_route53_resolver_firewall_rule" "allow_llm_apis" {
  name                    = "allow-llm-apis"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.bot_egress.id
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.allowed.id
  action                  = "ALLOW"
  priority                = 100
}

resource "aws_route53_resolver_firewall_rule" "block_everything" {
  name                    = "block-everything-else"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.bot_egress.id
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.block_all.id
  action                  = "BLOCK"
  block_response          = "NODATA"
  priority                = 200
}

resource "aws_route53_resolver_firewall_rule_group_association" "bot_vpc" {
  name                   = "${var.project_name}-bot-vpc"
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.bot_egress.id
  vpc_id                 = aws_vpc.main.id
  priority               = 100
}

# =============================================================================
# PHASE 2: Additional Security Layers
# =============================================================================

# --- Network Firewall ---
# L7 domain inspection on TLS SNI. Catches hardcoded IPs bypassing DNS.
# Deferred to Phase 2 for simplicity.
#
# resource "aws_networkfirewall_firewall" "bots" {
#   name        = "${var.project_name}-network-firewall"
#   vpc_id      = aws_vpc.main.id
#   firewall_policy_arn = aws_networkfirewall_firewall_policy.bots.arn
#
#   subnet_mapping {
#     subnet_id = aws_subnet.public.id
#   }
# }

# --- VPC Endpoints ---
# Avoids routing ECR/S3 traffic through NAT gateway.
#
# resource "aws_vpc_endpoint" "s3" {
#   vpc_id       = aws_vpc.main.id
#   service_name = "com.amazonaws.${var.region}.s3"
#   route_table_ids = [aws_route_table.private.id]
# }
#
# resource "aws_vpc_endpoint" "ecr_dkr" {
#   vpc_id              = aws_vpc.main.id
#   service_name        = "com.amazonaws.${var.region}.ecr.dkr"
#   vpc_endpoint_type   = "Interface"
#   subnet_ids          = [aws_subnet.private.id]
#   security_group_ids  = [aws_security_group.bot.id]
#   private_dns_enabled = true
# }

# --- WAF on ALB ---
# Rate-limit public websocket connections to prevent abuse.
# Requires ALB in front of game containers (also Phase 2).
#
# resource "aws_wafv2_web_acl" "game" {
#   name  = "${var.project_name}-game-waf"
#   scope = "REGIONAL"
#   default_action { allow {} }
#   rule {
#     name     = "rate-limit"
#     priority = 1
#     action { block {} }
#     statement {
#       rate_based_statement {
#         limit              = 1000
#         aggregate_key_type = "IP"
#       }
#     }
#     visibility_config {
#       sampled_requests_enabled   = true
#       cloudwatch_metrics_enabled = true
#       metric_name                = "rate-limit"
#     }
#   }
#   visibility_config {
#     sampled_requests_enabled   = true
#     cloudwatch_metrics_enabled = true
#     metric_name                = "game-waf"
#   }
# }
