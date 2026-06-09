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
      "ecs:TagResource",
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
      "logs:FilterLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.ecs_tasks.arn}:*",
      "arn:aws:logs:${var.region}:*:log-group:/aws/ecs/containerinsights/${aws_ecs_cluster.main.name}/performance:*",
    ]
  }

  # EC2 network interface describe (for resolving task public IPs).
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeNetworkInterfaces"]
    resources = ["*"]
  }

  # S3 access for uploading game configs (read-only for containers via presigned URLs).
  # Only the orchestrator (dashboard role on EC2, or laptop dev principal) writes.
  # Containers use presigned GETs; no s3 perms are granted to ecs_task role.
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.game_configs.arn,
      "${aws_s3_bucket.game_configs.arn}/*"
    ]
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

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    # Add treeform's SSH key first so manual recovery is always possible.
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHU4HFzwSyzHzO0MIyTnKScxs8WBO3sLGlndKC2Gq800 andre@vonhouck.com" >> /home/ubuntu/.ssh/authorized_keys
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys

    apt-get update
    apt-get install -y docker.io unzip curl
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu

    # awscli v2 (Ubuntu 24.04 dropped the apt awscli package).
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip
  EOF

  tags = { Name = "${var.project_name}-dashboard" }

  lifecycle {
    ignore_changes = [
      ami,
      # We manage the public IP via explicit aws_eip_association.
      # Prevent TF from trying to re-enable auto-assign on recreate.
      associate_public_ip_address,
    ]
  }
}

# =============================================================================
# Elastic IP for stable public access (Observatory proxy + SSH)
# =============================================================================
# We attach a static Elastic IP so the dashboard has a reliable public address
# that does not change on stop/start or replacement. This is a prerequisite
# for the Observatory reverse proxy MVP (IP-range access control).

resource "aws_eip" "dashboard" {
  domain = "vpc"

  tags = { Name = "${var.project_name}-dashboard" }
}

resource "aws_eip_association" "dashboard" {
  instance_id   = aws_instance.dashboard.id
  allocation_id = aws_eip.dashboard.id
}

# =============================================================================
# SSH Key
# =============================================================================

resource "aws_key_pair" "dashboard" {
  key_name   = "${var.project_name}-dashboard"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN0CuDAfvVmnghhbhaaJxMdiwx06X3vjJjyry65qvGlp monofuel@nixos"
}
