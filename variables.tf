# ============================================================
# Variabel input
# Isi nilainya di terraform.tfvars (lihat terraform.tfvars.example)
# ============================================================

variable "region" {
  description = "Region AWS utama"
  type        = string
  default     = "ap-southeast-1"
}

variable "availability_zone" {
  description = "AZ untuk NAT gateway dan private subnet (harus sama agar tidak kena biaya cross-AZ)"
  type        = string
  default     = "ap-southeast-1a"
}

variable "project" {
  description = "Nama project, dipakai sebagai prefix nama resource"
  type        = string
  default     = "fikom"
}

variable "environment" {
  description = "Nama environment"
  type        = string
  default     = "production"
}

# ---------- Penamaan resource ----------
variable "ecr_repo_name" {
  description = "Nama repository ECR"
  type        = string
  default     = "fikomecs"
}

variable "container_name" {
  description = "Nama container di task definition. HARUS konsisten dengan CI/CD dan command override."
  type        = string
  default     = "fikomecs"
}

variable "uploads_bucket" {
  description = "Bucket S3 untuk upload foto (privat, diakses lewat presigned URL)"
  type        = string
}

variable "frontend_bucket" {
  description = "Bucket S3 untuk hosting frontend (privat, dibaca CloudFront lewat OAC)"
  type        = string
}

# ---------- Jaringan ----------
variable "private_subnet_cidr" {
  description = "CIDR private subnet. Pastikan TIDAK overlap dengan subnet yang sudah ada."
  type        = string
  default     = "172.31.200.0/24"
}

# ---------- Domain ----------
variable "api_domain" {
  description = "Domain untuk backend API (di depan ALB)"
  type        = string
  # contoh: apiecs.fikom.net
}

variable "frontend_domain" {
  description = "Domain untuk frontend (di depan CloudFront)"
  type        = string
  # contoh: ecs.fikom.net
}

# ---------- Database (server sendiri, di luar AWS) ----------
variable "db_host" {
  description = "Host/IP server PostgreSQL"
  type        = string
}

variable "db_port" {
  description = "Port PostgreSQL"
  type        = string
  default     = "5432"
}

variable "db_name" {
  description = "Nama database"
  type        = string
}

variable "db_username" {
  description = "Username database. Kode membaca DATABASE_USERNAME (bukan DATABASE_USER)."
  type        = string
}

variable "db_ssl" {
  description = "Aktifkan SSL ke database. Disarankan true untuk koneksi lintas internet."
  type        = string
  default     = "false"
}

# ---------- Aplikasi ----------
variable "container_port" {
  description = "Port yang didengarkan aplikasi di dalam container"
  type        = number
  default     = 4000
}

variable "task_cpu" {
  description = "CPU unit Fargate (256/512/1024/...)"
  type        = string
  default     = "512"
}

variable "task_memory" {
  description = "Memory MiB Fargate. Harus kombinasi valid dengan task_cpu."
  type        = string
  default     = "1024"
}

variable "desired_count" {
  description = "Jumlah task yang berjalan"
  type        = number
  default     = 1
}

variable "image_tag" {
  description = "Tag image ECR yang dideploy. CI/CD akan menimpanya dengan commit SHA."
  type        = string
  default     = "latest"
}

variable "jwt_expires_in" {
  description = "Masa berlaku JWT"
  type        = string
  default     = "12h"
}

variable "bcrypt_rounds" {
  description = "Bcrypt cost factor"
  type        = string
  default     = "12"
}

variable "log_retention_days" {
  description = "Retensi CloudWatch Logs (hari)"
  type        = number
  default     = 30
}

variable "signed_url_ttl" {
  description = "Masa berlaku presigned URL S3 (detik)"
  type        = string
  default     = "3600"
}

variable "db_password_secret_name" {
  description = "Nama secret berisi password database (dikelola di luar Terraform)"
  type        = string
  default     = "fikom/DATABASE_PASSWORD"
}

variable "jwt_secret_name" {
  description = "Nama secret berisi JWT signing key (dikelola di luar Terraform)"
  type        = string
  default     = "fikom/JWT_SECRET"
}