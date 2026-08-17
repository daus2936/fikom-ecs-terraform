# ============================================================
# ALB + ACM (backend API)
# ------------------------------------------------------------
# Sertifikat ALB berada di region yang SAMA dengan ALB (regional service),
# berbeda dari sertifikat CloudFront yang wajib di us-east-1.
# ============================================================

resource "aws_acm_certificate" "api" {
  domain_name       = var.api_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Menunggu sertifikat berstatus ISSUED.
# Karena DNS dikelola di luar Route 53, record validasi DITAMBAHKAN MANUAL
# (lihat output `acm_validation_records`). Resource ini akan menunggu
# sampai validasi selesai, lalu apply dilanjutkan.
resource "aws_acm_certificate_validation" "api" {
  certificate_arn = aws_acm_certificate.api.arn

  timeouts {
    create = "45m"
  }
}

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]

  # ALB butuh minimal 2 subnet di AZ berbeda
  subnets = local.public_subnet_ids

  enable_deletion_protection = false # set true untuk produksi mapan
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.project}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip" # wajib "ip" untuk Fargate/awsvpc

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Beri waktu request selesai saat task lama dimatikan
  deregistration_delay = 30
}

# HTTP -> naikkan ke HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.api.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
