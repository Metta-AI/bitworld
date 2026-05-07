# Security groups and DNS Firewall for bot egress control.
#
# Threat model: bots run arbitrary user code. They must ONLY be able to:
#   1. Connect to the game server (websocket)
#   2. Call whitelisted LLM APIs (OpenAI, Anthropic, etc.)
#   3. Resolve DNS for allowed domains only
#
# Everything else is blocked. This is already better than the metta
# tournament platform which has zero network restrictions.

# --- Game Server Security Group ---

resource "aws_security_group" "game_server" {
  name        = "${var.project_name}-game-server"
  description = "Game server - public websocket + SSH"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-game-server-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "game_server_ws" {
  security_group_id = aws_security_group.game_server.id
  description       = "WebSocket from players and bots"
  from_port         = var.game_server_port
  to_port           = var.game_server_port
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "game_server_ssh" {
  security_group_id = aws_security_group.game_server.id
  description       = "SSH - Phase 2: lock to admin CIDR"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "game_server_all" {
  security_group_id = aws_security_group.game_server.id
  description       = "Game server needs outbound for image pulls, bot comms"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Bot Security Group ---
# Bots are in private subnet with no public IP. They can only:
# - Talk to game server on the game port
# - Make HTTPS calls to LLM APIs (DNS Firewall restricts destinations)
# - Resolve DNS via the VPC resolver

resource "aws_security_group" "bot" {
  name        = "${var.project_name}-bot"
  description = "Bot containers - restricted egress only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-bot-sg" }
}

resource "aws_vpc_security_group_egress_rule" "bot_to_game_server" {
  security_group_id            = aws_security_group.bot.id
  description                  = "Connect to game server websocket"
  from_port                    = var.game_server_port
  to_port                      = var.game_server_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.game_server.id
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

# --- Route 53 DNS Firewall ---
# Default-deny DNS resolution. Only domains in the allowlist resolve.
# This prevents bots from reaching arbitrary internet services.

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

# --- PHASE 2: AWS Network Firewall ---
# If bots bypass DNS by hardcoding IPs, this does L7 domain inspection
# on actual TLS SNI. Only enable if abuse is detected.
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
#
# resource "aws_networkfirewall_firewall_policy" "bots" {
#   name = "${var.project_name}-bot-policy"
#
#   firewall_policy {
#     stateless_default_actions          = ["aws:forward_to_sfe"]
#     stateless_fragment_default_actions = ["aws:forward_to_sfe"]
#
#     stateful_rule_group_reference {
#       resource_arn = aws_networkfirewall_rule_group.allow_llm.arn
#     }
#   }
# }

# --- PHASE 2: VPC Endpoints ---
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
#
# resource "aws_vpc_endpoint" "ecr_api" {
#   vpc_id              = aws_vpc.main.id
#   service_name        = "com.amazonaws.${var.region}.ecr.api"
#   vpc_endpoint_type   = "Interface"
#   subnet_ids          = [aws_subnet.private.id]
#   security_group_ids  = [aws_security_group.bot.id]
#   private_dns_enabled = true
# }

# --- PHASE 2: WAF on ALB ---
# Rate-limit public websocket connections to prevent abuse.
# Requires ALB in front of game server (also Phase 2).
#
# resource "aws_wafv2_web_acl" "game_server" {
#   name  = "${var.project_name}-game-server-waf"
#   scope = "REGIONAL"
#
#   default_action { allow {} }
#
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
#
#   visibility_config {
#     sampled_requests_enabled   = true
#     cloudwatch_metrics_enabled = true
#     metric_name                = "game-server-waf"
#   }
# }
