# Security groups and DNS Firewall for container egress control.
#
# =============================================================================
# TRUST BOUNDARIES
# =============================================================================
#
# | Container       | Trust Level | Who writes the code?                     |
# |-----------------|-------------|------------------------------------------|
# | Dashboard       | TRUSTED     | Us (games_server binary, our EC2)        |
# | Game containers | UNTRUSTED   | Arbitrary user-uploaded Docker images    |
# | Bot containers  | UNTRUSTED   | Arbitrary user-uploaded Docker images    |
#
# Dashboard is the ONLY trusted component. It orchestrates everything,
# holds API keys, and has AWS credentials (EC2 instance role). If it is
# compromised, everything is compromised.
#
# Game containers and bot containers are BOTH untrusted. Users upload
# arbitrary Docker images that we run on Fargate. Assume they will
# attempt to: mine crypto, exfiltrate data, scan the VPC, abuse egress
# as an attack platform, or serve malicious content to browsers.
#
# =============================================================================
# ALLOWED NETWORK ACCESS (per container type)
# =============================================================================
#
# Game containers:
#   INBOUND:  port 8080 from internet (spectators) + from bot SG
#   OUTBOUND: ONLY to dashboard SG on replay upload port. Nothing else.
#
# Bot containers:
#   INBOUND:  none (bots initiate all connections)
#   OUTBOUND: port 8080 to game SG, port 443 to 0.0.0.0/0 (DNS-firewalled),
#             port 53 to VPC resolver only
#
# Dashboard:
#   INBOUND:  port 2080 (web UI), port 22 (SSH — lock down before prod)
#   OUTBOUND: unrestricted (needs ECS API, GHCR pulls, etc.)
#
# Everything else is blocked.

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

resource "aws_vpc_security_group_ingress_rule" "dashboard_replay_upload" {
  security_group_id            = aws_security_group.dashboard.id
  description                  = "Game containers POST replays to games_server"
  from_port                    = var.replay_upload_port
  to_port                      = var.replay_upload_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.game_container.id
}

# WARNING: SSH open to the entire internet. This machine runs games_server
# which orchestrates ECS tasks and holds LLM API keys in env vars.
# Replace with SSM Session Manager (no SSH port needed) or restrict to
# admin CIDR before production traffic.
resource "aws_vpc_security_group_ingress_rule" "dashboard_ssh" {
  security_group_id = aws_security_group.dashboard.id
  description       = "SSH - WARNING: open to internet, lock down before prod"
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
#
# SECURITY: Game containers run UNTRUSTED user-uploaded Docker images.
# They have NO internet egress. The only outbound path is to games_server
# for replay uploads. This prevents crypto mining, use as an attack
# platform, and lateral movement within the VPC.
# Do NOT add internet egress here without also adding Network Firewall.
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

# --- PHASE 2: HTTPS/WSS via ALB ---
# Replace public ingress on 8080 with ALB on 443. ALB terminates TLS,
# forwards to game containers on 8080 via target group. Gives wss://
# for free and removes direct public IP exposure.
# Requires: ACM certificate, Route 53 DNS record, ALB in public subnet.
#
# SECURITY: Without an ALB, untrusted game containers have a direct public
# IP. They can serve phishing pages, XSS, or arbitrary content to browsers.
# The ALB only forwards valid websocket/HTTP traffic to port 8080, blocking
# abuse of the public-facing connection.

resource "aws_vpc_security_group_ingress_rule" "game_container_from_bot" {
  security_group_id            = aws_security_group.game_container.id
  description                  = "Bots connect to their assigned game"
  from_port                    = var.game_container_port
  to_port                      = var.game_container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bot.id
}

resource "aws_vpc_security_group_egress_rule" "game_container_to_dashboard" {
  security_group_id            = aws_security_group.game_container.id
  description                  = "Replay upload to games_server (only outbound game containers need)"
  from_port                    = var.replay_upload_port
  to_port                      = var.replay_upload_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.dashboard.id
}

# =============================================================================
# Bot Containers (ECS Fargate, private subnet)
# Untrusted user code. No public IP. Heavily restricted egress.
#
# Bots initiate ALL connections. No service listens inside a bot container.
# If you think you need ingress here, your architecture is wrong — bots
# connect to game containers, not the other way around.
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

# NOTE: Port 443 is open to 0.0.0.0/0 but DNS Firewall restricts which
# domains resolve. A bot CAN bypass this by hardcoding an IP address.
# Network Firewall (Phase 2) closes this gap by inspecting TLS SNI.
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
# Applied at VPC level — affects ALL containers and the dashboard.
#
# Game containers don't need DNS because games_server injects the replay
# upload URL as a raw IP in the container's env vars.
#
# Dashboard (games_server) also goes through this firewall but has
# unrestricted egress at the SG level. If dashboard DNS breaks, add the
# needed domains to var.infra_domains, do NOT disable the firewall.
# =============================================================================

resource "aws_route53_resolver_firewall_domain_list" "allowed" {
  name    = "${var.project_name}-allowed-domains"
  domains = concat(var.llm_api_domains, var.infra_domains)
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
  priority               = 101
}

# =============================================================================
# PHASE 2: Additional Security Layers
# =============================================================================

# --- Network Firewall ---
# DNS Firewall only blocks domain resolution. A malicious bot can still
# HTTPS to a hardcoded IP (e.g. curl https://104.18.0.1/) and bypass the
# allowlist entirely. Network Firewall inspects TLS SNI on every outbound
# connection and drops traffic to domains not on the allowlist — even if
# the bot never used DNS to resolve the IP.
# Enable this before accepting untrusted bot images from external users.
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
# Without rate limiting, a single client can open thousands of websocket
# connections to a game container, exhausting its memory and CPU.
# WAF on an ALB caps connections per source IP.
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

# =============================================================================
# PHASE 2: Additional Hardening for Untrusted Images
# =============================================================================

# --- ECR Image Scanning ---
# Scan user-submitted images for known CVEs before allowing them to run.
# Won't catch custom malware but catches lazy attacks using known exploits.
# If using GHCR instead of ECR, consider a pre-launch scan step in
# games_server that pulls the image and runs `docker scout` or Trivy.
#
# resource "aws_ecr_registry_scanning_configuration" "scan" {
#   scan_type = "ENHANCED"
#   rule {
#     scan_frequency = "SCAN_ON_PUSH"
#     repository_filter {
#       filter      = "*"
#       filter_type = "WILDCARD"
#     }
#   }
# }

# --- ECS Exec ---
# ECS Exec is DISABLED by default. Do NOT enable it for untrusted task
# definitions. If enabled, anyone with the task ARN and ECS API access
# could shell into a running game container via SSM. Only enable for
# debugging trusted containers with a separate task role that has
# ssmmessages:* permissions.

# --- Game Duration Timeout ---
# ECS has no built-in task TTL. A malicious game container will run (and
# bill vCPU-seconds) until someone manually stops it. games_server MUST
# enforce a max game duration (e.g. 30 minutes) and call stop-task after
# that. ECS stopTimeout only controls graceful shutdown duration, not
# total runtime. This is enforced in games_server code, not terraform.

# --- S3 Replay Bucket Policy ---
# The replay bucket should deny all principals except games_server's
# EC2/IAM role. Even if someone discovers the bucket name, they cannot
# read or write replays without the correct role. Containers never get
# direct S3 access — replays go through games_server's upload proxy.
#
# resource "aws_s3_bucket" "replays" {
#   bucket = "${var.project_name}-replays"
# }
#
# resource "aws_s3_bucket_lifecycle_configuration" "replays" {
#   bucket = aws_s3_bucket.replays.id
#   rule {
#     id     = "expire-old-replays"
#     status = "Enabled"
#     expiration { days = 30 }
#   }
# }
#
# resource "aws_s3_bucket_policy" "replays" {
#   bucket = aws_s3_bucket.replays.id
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Sid       = "DenyAllExceptGamesServer"
#       Effect    = "Deny"
#       Principal = "*"
#       Action    = "s3:*"
#       Resource  = [
#         aws_s3_bucket.replays.arn,
#         "${aws_s3_bucket.replays.arn}/*"
#       ]
#       Condition = {
#         StringNotEquals = {
#           "aws:PrincipalArn" = aws_iam_role.dashboard_ec2.arn
#         }
#       }
#     }]
#   })
# }

# --- GuardDuty ---
# Monitors for crypto mining signatures, DNS anomalies, and credential
# exfiltration at the AWS account level. Low effort to enable, catches
# unsophisticated attacks. ECS Runtime Monitoring detects suspicious
# process activity inside containers (e.g. reverse shells, port scans).
#
# resource "aws_guardduty_detector" "main" {
#   enable = true
#   datasources {
#     s3_logs      { enable = true }
#     kubernetes   { audit_logs { enable = false } }
#     malware_protection { scan_ec2_instance_with_findings { ebs_volumes { enable = true } } }
#   }
# }

# --- NAT Gateway IP ---
# The NAT gateway's Elastic IP (output: nat_gateway_public_ip) is the
# single egress IP for all bot containers. If an LLM provider requires
# IP allowlisting, give them this IP. Do not delete the NAT gateway
# thinking "bots don't need internet" — DNS Firewall restricts
# destinations, but the NAT is the path that makes allowed HTTPS work.
