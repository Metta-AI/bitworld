variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tags"
  type        = string
  default     = "bitworld"
}

variable "environment" {
  description = "Deployment environment (production, staging, dev)"
  type        = string
  default     = "production"
}

variable "owner" {
  description = "Team or person responsible for this infrastructure"
  type        = string
  default     = "treeform"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for public subnet (game server, NAT gateway)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for private subnet (bot containers)"
  type        = string
  default     = "10.0.128.0/24"
}

variable "availability_zone" {
  description = "AZ for MVP (single-AZ is fine for tournaments)"
  type        = string
  default     = "us-east-1a"
}

variable "dashboard_port" {
  description = "Port the games_server dashboard listens on (HTTP + management UI)"
  type        = number
  default     = 2080
}

variable "game_container_port" {
  description = "Port each game container listens on (all use the same port, each has its own IP)"
  type        = number
  default     = 8080
}

# NOTE: Defaults to same port as dashboard (2080) for MVP. This means game
# containers can technically reach the dashboard UI too. Split to a separate
# port when games_server moves to EC2 and serves public traffic — you don't
# want untrusted game containers hitting the management API.
variable "replay_upload_port" {
  description = "Port on games_server that game containers POST replays to"
  type        = number
  default     = 2080
}

variable "llm_api_domains" {
  description = "Domains allowed through DNS Firewall for bot LLM access"
  type        = list(string)
  default = [
    "api.openai.com",
    "api.anthropic.com",
    "generativelanguage.googleapis.com",
    "api.together.ai",
    "api.x.ai",
  ]
}

variable "infra_domains" {
  description = "Domains needed for container infrastructure (image pulls, etc)"
  type        = list(string)
  default = [
    "ghcr.io",
    "*.ghcr.io",
    "pkg-containers.githubusercontent.com",
    "*.pkg-containers.githubusercontent.com",
  ]
}
