output "vpc_id" {
  description = "VPC ID for ECS cluster and other resources"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public subnet for game server and ALB"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "Private subnet for bot containers (ECS Fargate)"
  value       = aws_subnet.private.id
}

output "game_server_sg_id" {
  description = "Security group to attach to game server EC2"
  value       = aws_security_group.game_server.id
}

output "bot_sg_id" {
  description = "Security group to attach to ECS bot tasks"
  value       = aws_security_group.bot.id
}

output "nat_gateway_public_ip" {
  description = "NAT gateway IP (useful if LLM providers need allowlisting)"
  value       = aws_eip.nat.public_ip
}

output "dns_firewall_rule_group_id" {
  description = "DNS Firewall rule group ID"
  value       = aws_route53_resolver_firewall_rule_group.bot_egress.id
}

# --- PHASE 2 Outputs ---
# Uncomment as resources are added.
#
# output "ecs_cluster_arn" {
#   description = "ECS cluster ARN for task launches"
#   value       = aws_ecs_cluster.main.arn
# }
#
# output "ecr_repository_urls" {
#   description = "ECR repository URLs for bot images"
#   value = {
#     among_them = aws_ecr_repository.among_them.repository_url
#     nottoodumb = aws_ecr_repository.nottoodumb.repository_url
#   }
# }
#
# output "replay_bucket_name" {
#   description = "S3 bucket for game replays"
#   value       = aws_s3_bucket.replays.bucket
# }
