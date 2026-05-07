# VPC with public subnet (game server) and private subnet (bots).
# Bots reach LLM APIs via NAT gateway. No direct internet access.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

# --- Internet Gateway (public subnet → internet) ---

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-igw" }
}

# --- Subnets ---

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = "${var.project_name}-private" }
}

# --- NAT Gateway (private subnet → internet via public subnet) ---

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${var.project_name}-nat" }
}

# --- Route Tables ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --- PHASE 2: VPC Flow Logs ---
# Useful for forensics if a bot does something suspicious.
#
# resource "aws_flow_log" "vpc" {
#   vpc_id               = aws_vpc.main.id
#   traffic_type         = "ALL"
#   log_destination_type = "cloud-watch-logs"
#   log_destination      = aws_cloudwatch_log_group.flow_logs.arn
#   iam_role_arn         = aws_iam_role.flow_logs.arn
# }
#
# resource "aws_cloudwatch_log_group" "flow_logs" {
#   name              = "/aws/vpc/flow-logs/${var.project_name}"
#   retention_in_days = 7
# }
