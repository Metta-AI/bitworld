# ECS Fargate cluster for running game and bot containers.
#
# Task definitions are registered dynamically by games_server via
# `aws ecs register-task-definition` — not managed here.

# =============================================================================
# ECS Cluster
# =============================================================================

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.project_name}-cluster" }
}

# =============================================================================
# Phase 2: CloudWatch Logs
# =============================================================================
# Requires IAM execution role (PowerUserAccess can't create IAM roles).
# For now, skip log configuration — use `aws ecs describe-tasks` for status.
#
# resource "aws_cloudwatch_log_group" "ecs_tasks" {
#   name              = "/ecs/${var.project_name}"
#   retention_in_days = 7
# }

# =============================================================================
# Phase 2: IAM Roles
# =============================================================================
# Execution role: needed for ECR pulls and CloudWatch logs.
# Not needed when pulling from public GHCR.
#
# Task role: needed if containers call AWS APIs (S3 replays, etc).
# Not needed for MVP.
#
# resource "aws_iam_role" "ecs_execution" {
#   name               = "${var.project_name}-ecs-execution"
#   assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
# }
#
# resource "aws_iam_role" "ecs_task" {
#   name               = "${var.project_name}-ecs-task"
#   assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
# }

# =============================================================================
# Phase 2: ECR Repositories
# =============================================================================
# Currently pulling from GHCR (ghcr.io/treeform/*). Migrate to ECR later
# for faster pulls and to avoid GHCR rate limits under heavy tournament load.
#
# resource "aws_ecr_repository" "among_them" {
#   name                 = "${var.project_name}/among-them"
#   image_tag_mutability = "MUTABLE"
#   force_delete         = true
# }
#
# resource "aws_ecr_repository" "nottoodumb" {
#   name                 = "${var.project_name}/nottoodumb"
#   image_tag_mutability = "MUTABLE"
#   force_delete         = true
# }
