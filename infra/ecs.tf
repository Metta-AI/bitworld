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
# CloudWatch Logs
# =============================================================================

resource "aws_cloudwatch_log_group" "ecs_tasks" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7
}

# =============================================================================
# IAM Roles
# =============================================================================

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  lifecycle { ignore_changes = [tags, tags_all] }
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  lifecycle { ignore_changes = [tags, tags_all] }
}

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
