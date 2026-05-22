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

output "dashboard_sg_id" {
  description = "Security group for the dashboard EC2 (games_server)"
  value       = aws_security_group.dashboard.id
}

output "game_container_sg_id" {
  description = "Security group for game container ECS tasks"
  value       = aws_security_group.game_container.id
}

output "bot_sg_id" {
  description = "Security group for bot container ECS tasks"
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

output "ecs_cluster_arn" {
  description = "ECS cluster ARN for task launches"
  value       = aws_ecs_cluster.main.arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_execution_role_arn" {
  description = "IAM role ARN for Fargate to pull images and write logs"
  value       = aws_iam_role.ecs_execution.arn
}

output "ecs_task_role_arn" {
  description = "IAM role ARN assumed by running containers"
  value       = aws_iam_role.ecs_task.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for ECS task logs"
  value       = aws_cloudwatch_log_group.ecs_tasks.name
}

output "dashboard_public_ip" {
  description = "Public IP of the dashboard EC2 instance"
  value       = aws_instance.dashboard.public_ip
}

output "dashboard_instance_id" {
  description = "Instance ID of the dashboard EC2"
  value       = aws_instance.dashboard.id
}

output "crewrift_repository_url" {
  description = "ECR repository URL for cogame-crewrift"
  value       = aws_ecr_repository.crewrift.repository_url
}
