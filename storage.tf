# ============================================================
# ECR, S3, Secrets Manager
# ============================================================

# ---------- ECR ----------
resource "aws_ecr_repository" "backend" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "MUTABLE" # tag :latest ditimpa tiap deploy

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Batasi jumlah image agar biaya storage tidak menumpuk
resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Simpan 20 image terbaru"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ---------- S3: bucket upload foto ----------
# PRIVAT. Diakses aplikasi lewat task role, disajikan ke browser lewat
# presigned URL berbatas waktu — bukan akses publik.
resource "aws_s3_bucket" "uploads" {
  bucket = var.uploads_bucket
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  versioning_configuration {
    status = "Enabled" # perlindungan dari penghapusan tak sengaja
  }
}

# ---------- S3: bucket frontend ----------
# Juga PRIVAT. Hanya CloudFront (lewat OAC) yang boleh membacanya.
resource "aws_s3_bucket" "frontend" {
  bucket = var.frontend_bucket
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------- Secrets Manager ----------
# Secret DIKELOLA DI LUAR TERRAFORM (dibuat & diisi manual lewat AWS CLI).
# Di sini Terraform hanya MEMBACA ARN-nya untuk dirujuk oleh task
# definition dan execution role policy.
#
# Keuntungan pola ini:
#   - Nilai rahasia tidak pernah masuk ke terraform.tfstate.
#   - `terraform destroy` TIDAK ikut menghapus secret (dan nilainya).
#   - Rotasi password cukup lewat AWS CLI, tanpa menyentuh Terraform.
#
# Prasyarat: kedua secret HARUS sudah ada sebelum `terraform apply`.
#   aws secretsmanager create-secret --name fikom/DATABASE_PASSWORD \
#     --secret-string 'PASSWORD_DB' --region ap-southeast-1
#   aws secretsmanager create-secret --name fikom/JWT_SECRET \
#     --secret-string "$(openssl rand -base64 48)" --region ap-southeast-1
data "aws_secretsmanager_secret" "db_password" {
  name = var.db_password_secret_name
}

data "aws_secretsmanager_secret" "jwt_secret" {
  name = var.jwt_secret_name
}
