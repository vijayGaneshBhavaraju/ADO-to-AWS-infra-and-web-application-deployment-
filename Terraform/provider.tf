terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"    # ← v6 → v5
    }
  }
}

provider "aws" {
  region = var.aws_region
}