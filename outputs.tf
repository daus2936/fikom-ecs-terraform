# ============================================================
# Outputs
# ============================================================

# ---------- Yang perlu ditambahkan ke DNS ----------
output "acm_validation_records" {
  description = "Record CNAME validasi ACM. Tambahkan ke DNS SEBELUM apply penuh."
  value = {
    api = [for o in aws_acm_certificate.api.domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }]
    frontend = [for o in aws_acm_certificate.frontend.domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }]
  }
}

output "dns_records_to_create" {
  description = "Record DNS aplikasi yang harus dibuat setelah apply"
  value = {
    "${var.api_domain}"      = "CNAME -> ${aws_lb.main.dns_name}"
    "${var.frontend_domain}" = "CNAME -> ${aws_cloudfront_distribution.frontend.domain_name}"
  }
}

# ---------- Jaringan ----------
output "nat_elastic_ip" {
  description = "IP TETAP untuk di-whitelist di pg_hba.conf / firewall server DB"
  value       = aws_eip.nat.public_ip
}

output "private_subnet_id" {
  description = "Subnet untuk one-off task (migrasi/seed) dan service"
  value       = aws_subnet.private.id
}

output "task_security_group_id" {
  description = "Security group task"
  value       = aws_security_group.task.id
}

# ---------- Endpoint ----------
output "alb_dns_name" {
  description = "DNS name ALB"
  value       = aws_lb.main.dns_name
}

output "cloudfront_domain_name" {
  description = "Domain CloudFront"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "cloudfront_distribution_id" {
  description = "Distribution ID (untuk invalidation di CI/CD)"
  value       = aws_cloudfront_distribution.frontend.id
}

# ---------- Nilai untuk CI/CD ----------
output "cicd_variables" {
  description = "Nilai yang diisikan ke Jenkins/GitLab"
  value = {
    AWS_ACCOUNT_ID       = data.aws_caller_identity.current.account_id
    AWS_DEFAULT_REGION   = var.region
    ECR_REGISTRY         = split("/", aws_ecr_repository.backend.repository_url)[0]
    ECR_REPO             = aws_ecr_repository.backend.name
    CONTAINER_NAME       = var.container_name
    ECS_CLUSTER          = aws_ecs_cluster.main.name
    ECS_SERVICE          = aws_ecs_service.backend.name
    ECS_TASK_FAMILY      = aws_ecs_task_definition.backend.family
    ECS_SUBNETS          = aws_subnet.private.id
    ECS_SECURITY_GROUPS  = aws_security_group.task.id
    ECS_ASSIGN_PUBLIC_IP = "DISABLED"
    FRONTEND_BUCKET      = aws_s3_bucket.frontend.bucket
    CLOUDFRONT_DIST_ID   = aws_cloudfront_distribution.frontend.id
    VITE_API_BASE_URL    = "https://${var.api_domain}"
  }
}

# ---------- Perintah one-off task ----------
output "migrate_command" {
  description = "Perintah menjalankan migrasi setelah apply"
  value       = <<-EOT
    aws ecs run-task \
      --cluster ${aws_ecs_cluster.main.name} \
      --task-definition ${aws_ecs_task_definition.backend.family} \
      --launch-type FARGATE --count 1 \
      --network-configuration "awsvpcConfiguration={subnets=[${aws_subnet.private.id}],securityGroups=[${aws_security_group.task.id}],assignPublicIp=DISABLED}" \
      --overrides '{"containerOverrides":[{"name":"${var.container_name}","command":["node","scripts/migrate.js"]}]}' \
      --region ${var.region}
  EOT
}

output "secret_arns" {
  description = "ARN secret — isi NILAINYA lewat AWS CLI setelah apply"
  value = {
    database_password = data.aws_secretsmanager_secret.db_password.arn
    jwt_secret        = data.aws_secretsmanager_secret.jwt_secret.arn
  }
}
