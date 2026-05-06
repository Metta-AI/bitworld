variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tags"
  type        = string
  default     = "bitworld2"
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

variable "game_server_port" {
  description = "WebSocket port the game server listens on"
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
