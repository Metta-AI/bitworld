terraform {
  required_version = ">= 1.5"

  backend "s3" {
    bucket         = "bitworld-terraform-state-sandbox-andre"
    key            = "infra/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "bitworld-terraform-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
    }
  }
}
