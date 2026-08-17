terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ----------------------------------------------------------
  # Remote state (SANGAT disarankan untuk produksi).
  # Bootstrap dulu bucket + tabel lock-nya (lihat panduan bagian 3),
  # baru aktifkan blok ini dan jalankan `terraform init -migrate-state`.
  # ----------------------------------------------------------
  backend "s3" {
     bucket         = "fikom-tfstate"
     key            = "ecs/production/terraform.tfstate"
     region         = "ap-southeast-1"
     dynamodb_table = "fikom-tfstate-lock"
     encrypt        = true
   }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront MEWAJIBKAN sertifikat ACM berada di us-east-1,
# terlepas dari region utama aplikasi.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
