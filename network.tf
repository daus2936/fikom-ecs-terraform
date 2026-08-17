# ============================================================
# Jaringan
# ------------------------------------------------------------
# Memakai default VPC yang sudah ada. Yang DIBUAT Terraform:
#   - Elastic IP + NAT gateway  -> IP keluar TETAP untuk whitelist di server DB
#   - Private subnet + route table -> tempat task ECS berjalan
#   - Security group ALB dan task
#
# Kenapa private subnet + NAT: server DB (di luar AWS) menyaring
# berdasarkan IP. Task di subnet publik mendapat IP publik yang BERUBAH
# tiap kali task lahir, sehingga tidak bisa di-whitelist secara stabil.
# ============================================================

data "aws_vpc" "default" {
  default = true
}

# Subnet default (satu per AZ) — dipakai sebagai subnet PUBLIK untuk ALB & NAT
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

locals {
  public_subnet_ids = [for s in data.aws_subnet.default : s.id]

  # NAT ditempatkan di AZ yang sama dengan private subnet
  nat_subnet_id = one([
    for s in data.aws_subnet.default : s.id
    if s.availability_zone == var.availability_zone
  ])
}

# ---------- Elastic IP: INI yang di-whitelist di pg_hba.conf server DB ----------
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = local.nat_subnet_id

  tags = {
    Name = "${var.project}-nat"
  }
}

# ---------- Private subnet untuk task ECS ----------
resource "aws_subnet" "private" {
  vpc_id            = data.aws_vpc.default.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  # Task tidak mendapat IP publik; keluar lewat NAT
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-private"
  }
}

resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-private-rt"
  }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---------- Security groups ----------
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "FIKOM ALB - terima HTTP/HTTPS dari internet"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP dari internet (di-redirect ke HTTPS)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS dari internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Keluar ke target"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "task" {
  name        = "${var.project}-task-sg"
  description = "FIKOM ECS tasks"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-task-sg"
  }
}

# Hanya ALB yang boleh menghubungi port aplikasi
resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  description                  = "Port aplikasi, hanya dari ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# Keluar: ECR, Secrets Manager, CloudWatch, S3, dan database
resource "aws_vpc_security_group_egress_rule" "task_all" {
  security_group_id = aws_security_group.task.id
  description       = "Akses keluar (ECR, Secrets, Logs, S3, DB)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
