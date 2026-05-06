# Bootstrap stack — creates S3 + DynamoDB for Terraform remote state.
# Run once via: nim r tools/infra.nim --bootstrap
# State is LOCAL and committed to the repo (chicken-egg problem).

terraform {
  required_version = ">= 1.5"

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
      Project   = "bitworld2"
      ManagedBy = "terraform-bootstrap"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "bucket_name" {
  type    = string
  default = "bitworld2-terraform-state"
}

variable "lock_table_name" {
  type    = string
  default = "bitworld2-terraform-lock"
}

# --- State Bucket ---

resource "aws_s3_bucket" "tfstate" {
  bucket = var.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Lock Table ---

resource "aws_dynamodb_table" "tflock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# --- Outputs ---

output "bucket_name" {
  value = aws_s3_bucket.tfstate.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.tfstate.arn
}

output "lock_table_name" {
  value = aws_dynamodb_table.tflock.name
}
