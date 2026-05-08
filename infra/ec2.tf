# Dashboard EC2 instance running games_server.
# Orchestrates ECS tasks, serves the web UI, receives replay uploads.

# =============================================================================
# IAM Role for Dashboard EC2
# =============================================================================

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dashboard_ec2" {
  name               = "${var.project_name}-dashboard-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  lifecycle { ignore_changes = [tags, tags_all] }
}

resource "aws_iam_instance_profile" "dashboard" {
  name = "${var.project_name}-dashboard"
  role = aws_iam_role.dashboard_ec2.name
}

data "aws_iam_policy_document" "dashboard_ec2" {
  # ECS task management.
  statement {
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:RunTask",
      "ecs:StopTask",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
    ]
    resources = ["*"]
  }

  # Pass execution and task roles to ECS tasks.
  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [
      aws_iam_role.ecs_execution.arn,
      aws_iam_role.ecs_task.arn,
    ]
  }

  # CloudWatch logs (for reading task logs).
  statement {
    effect = "Allow"
    actions = [
      "logs:GetLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.ecs_tasks.arn}:*"]
  }

  # EC2 network interface describe (for resolving task public IPs).
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeNetworkInterfaces"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "dashboard_ec2" {
  name   = "${var.project_name}-dashboard-ec2"
  role   = aws_iam_role.dashboard_ec2.id
  policy = data.aws_iam_policy_document.dashboard_ec2.json
}

# =============================================================================
# EC2 Instance
# =============================================================================

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "dashboard" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.dashboard_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.dashboard.id]
  iam_instance_profile   = aws_iam_instance_profile.dashboard.name
  key_name               = aws_key_pair.dashboard.key_name

  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update
    apt-get install -y docker.io awscli unzip
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu
  EOF

  tags = { Name = "${var.project_name}-dashboard" }

  lifecycle { ignore_changes = [ami, user_data] }
}

# =============================================================================
# SSH Key
# =============================================================================

resource "aws_key_pair" "dashboard" {
  key_name   = "${var.project_name}-dashboard"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN0CuDAfvVmnghhbhaaJxMdiwx06X3vjJjyry65qvGlp monofuel@nixos"
}
