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

# Shared by all tasks (game + bot). This is fine — the execution role only
# grants "pull images from registry + write logs to CloudWatch". It does NOT
# give containers any runtime AWS access. If you add ECR pull-through cache
# or Secrets Manager references, consider splitting into per-type roles.
resource "aws_iam_role" "ecs_execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  lifecycle { ignore_changes = [tags, tags_all] }
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Public ECR pull permissions (for images published to public.ecr.aws like crewrift etc.).
# The default AmazonECSTaskExecutionRolePolicy only covers private ECR.
data "aws_iam_policy_document" "ecs_execution_ecr_public" {
  statement {
    effect = "Allow"
    actions = [
      "ecr-public:GetAuthorizationToken",
      "sts:GetServiceBearerToken",
      "ecr-public:BatchGetImage",
      "ecr-public:GetDownloadUrlForLayer",
      "ecr-public:DescribeRepositories",
      "ecr-public:DescribeImages",
      "ecr-public:BatchCheckLayerAvailability",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecs_execution_ecr_public" {
  name   = "${var.project_name}-ecs-execution-ecr-public"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_execution_ecr_public.json
}

# INTENTIONALLY has no attached policies. Containers must not access AWS
# APIs. Replay uploads go through games_server's upload proxy, not direct
# S3 access. Do NOT attach S3, SQS, or any other policy here — if a
# container needs to upload data, it goes through games_server which has
# its own EC2 instance role with scoped permissions.
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
