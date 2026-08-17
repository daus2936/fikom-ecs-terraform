# ============================================================
# IAM
# ------------------------------------------------------------
# Dua peran dengan tanggung jawab berbeda:
#
#   task role      = identitas APLIKASI saat berjalan. Hanya S3.
#                    Inilah yang membuat tidak ada access key di container.
#   execution role = dipakai ECS saat MENYIAPKAN task: tarik image dari ECR,
#                    ambil secret, tulis log. Tidak punya akses S3 sama sekali.
#
# Pemisahan ini disengaja: kalau salah satu bocor, dampaknya terbatas.
# ============================================================

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---------- Task role: akses S3 uploads ----------
resource "aws_iam_role" "task" {
  name               = "${var.project}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task_s3" {
  statement {
    sid    = "UploadsBucketObjectAccess"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.uploads.arn}/*"]
  }
}

resource "aws_iam_role_policy" "task_s3" {
  name   = "${var.project}-task-s3"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_s3.json
}

# ---------- Execution role: ECR + Secrets + Logs ----------
resource "aws_iam_role" "execution" {
  name               = "${var.project}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # action ini tidak mendukung pembatasan resource
  }

  statement {
    sid    = "EcrPullImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.backend.arn]
  }

  statement {
    sid       = "ReadSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [
      data.aws_secretsmanager_secret.db_password.arn,
      data.aws_secretsmanager_secret.jwt_secret.arn,
    ]
  }

  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    # Format ARN log group: log-group:/ecs/... (BUKAN repository/...)
    resources = ["${aws_cloudwatch_log_group.backend.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "${var.project}-execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}
