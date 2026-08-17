# ============================================================
# ECS: log group, cluster, task definition, service
# ============================================================

# Log group dibuat EKSPLISIT. Execution role hanya boleh MENULIS log,
# bukan membuat group-nya — kalau group belum ada, task gagal start.
resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.project}-backend"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # aktifkan kalau butuh metrik detail (ada biaya)
  }
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = "${aws_ecr_repository.backend.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "NODE_ENV", value = "production" },
        # HOST WAJIB 0.0.0.0 di container: ini alamat BIND, bukan connect.
        # Dengan 127.0.0.1, ALB tidak akan bisa menjangkau task.
        { name = "HOST", value = "0.0.0.0" },
        { name = "PORT", value = tostring(var.container_port) },
        { name = "TZ", value = "Asia/Jakarta" },
        { name = "CORS_ORIGIN", value = "https://${var.frontend_domain}" },
        { name = "JWT_EXPIRES_IN", value = var.jwt_expires_in },
        { name = "BCRYPT_ROUNDS", value = var.bcrypt_rounds },
        { name = "DATABASE_HOST", value = var.db_host },
        { name = "DATABASE_PORT", value = var.db_port },
        { name = "DATABASE_NAME", value = var.db_name },
        # Kode membaca DATABASE_USERNAME (bukan DATABASE_USER)
        { name = "DATABASE_USERNAME", value = var.db_username },
        { name = "DATABASE_SSL", value = var.db_ssl },
        { name = "STORAGE_DRIVER", value = "s3" },
        { name = "AWS_REGION", value = var.region },
        { name = "S3_BUCKET", value = aws_s3_bucket.uploads.bucket },
        { name = "S3_SIGNED_URL_TTL", value = var.signed_url_ttl },
      ]

      # Nilai rahasia disuntikkan ECS saat runtime, tidak pernah tersimpan
      # di task definition maupun terraform state.
      secrets = [
        {
          name      = "DATABASE_PASSWORD"
          valueFrom = data.aws_secretsmanager_secret.db_password.arn
        },
        {
          name      = "JWT_SECRET"
          valueFrom = data.aws_secretsmanager_secret.jwt_secret.arn
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      # ECS mengabaikan HEALTHCHECK di Dockerfile, jadi dideklarasikan di sini.
      # 127.0.0.1 benar: ini container menghubungi dirinya sendiri (loopback).
      healthCheck = {
        command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:'+(process.env.PORT||4000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    }
  ])
}

resource "aws_ecs_service" "backend" {
  name            = "${var.project}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Beri waktu aplikasi boot sebelum health check ALB dihitung
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = [aws_subnet.private.id]
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false # keluar lewat NAT agar IP tetap
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = var.container_name
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true # deploy gagal -> otomatis kembali ke revisi sebelumnya
  }

  lifecycle {
    # CI/CD mendaftarkan revisi task definition baru tiap deploy.
    # Tanpa ini, `terraform apply` berikutnya akan menarik service
    # kembali ke revisi yang dikenal Terraform.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.https]
}
