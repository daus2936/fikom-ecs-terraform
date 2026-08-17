# ============================================================
# CloudFront + ACM us-east-1 (frontend)
# ------------------------------------------------------------
# CloudFront adalah layanan GLOBAL dan hanya membaca sertifikat dari
# us-east-1 — karena itu provider alias us_east_1 dipakai di sini.
# Ini murni lokasi metadata; trafik tetap dilayani dari edge terdekat.
# ============================================================

resource "aws_acm_certificate" "frontend" {
  provider = aws.us_east_1

  domain_name       = var.frontend_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "frontend" {
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.frontend.arn

  timeouts {
    create = "45m"
  }
}

# OAC menggantikan OAI (legacy). Inilah yang memungkinkan bucket
# tetap PRIVAT sementara CloudFront tetap bisa membacanya.
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project}-frontend-oac"
  description                       = "OAC untuk bucket frontend FIKOM"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Managed cache policy "CachingOptimized" bawaan AWS
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.project} frontend"
  default_root_object = "index.html"
  price_class         = "PriceClass_All"
  aliases             = [var.frontend_domain]

  origin {
    origin_id                = "s3-${var.frontend_bucket}"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${var.frontend_bucket}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
  }

  # Routing SPA: React Router menangani rute di sisi klien, sehingga
  # refresh di /invoices akan meminta objek yang tidak ada di S3.
  # Bucket privat membalas 403 (bukan 404), jadi keduanya dipetakan
  # ke index.html dengan status 200.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.frontend.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# Bucket policy: izin baca HANYA untuk distribution ini.
# Bukan akses publik — dibatasi lewat kondisi AWS:SourceArn.
data "aws_iam_policy_document" "frontend_oac" {
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_oac.json

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}
