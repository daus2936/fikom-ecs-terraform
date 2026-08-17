# Deployment Guide — AWS ECS Fargate with Terraform

A practical, end-to-end guide for provisioning this stack on AWS with Terraform, starting from an empty account.

**43 resources**, built across **two `terraform apply` runs** with manual steps in between. Expect **45–75 minutes**, most of it waiting on ACM validation and CloudFront propagation.

---

## What gets deployed

- **Backend** — Node.js (Fastify) on ECS Fargate, in a private subnet behind an Application Load Balancer
- **Frontend** — React/Vite static build in a private S3 bucket, served through CloudFront with Origin Access Control
- **Uploads** — Amazon S3, served via time-limited presigned URLs
- **Database** — self-hosted PostgreSQL **outside AWS**, reached through a NAT Gateway with a fixed Elastic IP

---

## Placeholders used in this guide

Substitute your own values before running any command:

| Placeholder | Meaning | Example |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | Your 12-digit AWS account ID | `123456789012` |
| `<REGION>` | Primary AWS region | `ap-southeast-1` |
| `<DB_HOST>` | Host/IP of the self-hosted PostgreSQL server | `db.internal.example.com` |
| `api.example.com` | Domain for the backend API (ALB) | your API subdomain |
| `app.example.com` | Domain for the frontend (CloudFront) | your app subdomain |
| `example.com` | Your DNS zone | your domain |

Resource names derive from the `project` variable (default `fikom`), producing `fikom-cluster`, `fikom-service`, `fikom-backend`, `/ecs/fikom-backend`, and so on.

> **Never commit `terraform.tfvars` or `*.tfstate`.** State files store resource attributes in plaintext, and `terraform.tfvars` holds your infrastructure specifics.

---

## Table of Contents

1. [File layout & prerequisites](#1-file-layout--prerequisites)
2. [Check for leftover resources](#2-check-for-leftover-resources) ← **don't skip**
3. [Bootstrap remote state](#3-bootstrap-remote-state)
4. [Apply #1 — foundation](#4-apply-1--foundation)
5. [Manual steps (run in parallel)](#5-manual-steps-run-in-parallel)
6. [Apply #2 — compute & delivery](#6-apply-2--compute--delivery)
7. [Application DNS](#7-application-dns)
8. [Database migration & seed](#8-database-migration--seed)
9. [Deploy the frontend](#9-deploy-the-frontend)
10. [Verification](#10-verification)
11. [Hand over to CI/CD](#11-hand-over-to-cicd)
12. [Cheat sheet](#12-cheat-sheet)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. File layout & prerequisites

```
terraform/
├── versions.tf      variables.tf     terraform.tfvars
├── network.tf       iam.tf           storage.tf
├── ecs.tf           alb.tf           cloudfront.tf
└── outputs.tf
```

Add a `.gitignore` in that folder:

```gitignore
terraform.tfvars
*.tfstate
*.tfstate.*
.terraform/
```

### Prerequisites

```bash
terraform version              # >= 1.6
aws --version                  # v2
aws sts get-caller-identity    # confirm the expected account
docker --version
node --version                 # 20.x
```

The application code must already include the S3 storage changes (`storage.js`, the upload route, `server.js`, `package.json`, and the frontend page that consumes `foto_url`), and `backend/Dockerfile` must end with `CMD ["node","src/server.js"]`.

### Terraform's scope vs. manual steps

| Managed by Terraform | Handled manually |
|---|---|
| VPC networking (EIP, NAT, private subnet, security groups) | **Values** of Secrets Manager secrets |
| IAM task role + execution role | DNS records (ACM validation & application) |
| ECR repo, two S3 buckets, log group | First image push to ECR |
| ECS cluster, task definition, service | Database migration & superadmin seed |
| ALB + target group + listeners + ACM | Uploading frontend build output |
| CloudFront + OAC + bucket policy | Allow-listing the Elastic IP on the database |

> Secret **values** are deliberately kept out of Terraform so they never land in `terraform.tfstate`, which stores attributes in plaintext.

---

## 2. Check for leftover resources

If you are rebuilding after a `terraform destroy`, three leftovers can block the apply in ways the error message won't make obvious. Five minutes here saves a lot of time later.

### 2.1 Secrets still inside their recovery window

The most common failure. Secrets deleted through the console keep a recovery period (30 days by default), during which **the name stays reserved** and cannot be recreated.

```bash
aws secretsmanager list-secrets --region <REGION> \
  --include-planned-deletion \
  --query "SecretList[?starts_with(Name,'fikom/')].{Name:Name,Deleted:DeletedDate}" --output table
```

If any appear with a `DeletedDate`, remove them permanently:

```bash
aws secretsmanager delete-secret --region <REGION> \
  --secret-id fikom/DATABASE_PASSWORD --force-delete-without-recovery
aws secretsmanager delete-secret --region <REGION> \
  --secret-id fikom/JWT_SECRET --force-delete-without-recovery
```

### 2.2 A CloudFront distribution that hasn't finished deleting

Distributions take time to disappear. While one still exists, its alias cannot be claimed by a new distribution (`CNAMEAlreadyExists`).

```bash
aws cloudfront list-distributions \
  --query "DistributionList.Items[].{Id:Id,Status:Status,Aliases:Aliases.Items}" --output table
```

This should be empty, or at least contain no entry for `app.example.com`.

### 2.3 Everything else

```bash
aws s3api list-buckets --query "Buckets[?starts_with(Name,'fikom')].Name"
aws ec2 describe-addresses --region <REGION> --query 'Addresses[].{Ip:PublicIp,Assoc:AssociationId}'
aws ec2 describe-nat-gateways --region <REGION> \
  --query "NatGateways[?State!='deleted'].{Id:NatGatewayId,State:State}"
aws acm list-certificates --region <REGION> --query 'CertificateSummaryList[].DomainName'
aws acm list-certificates --region us-east-1 --query 'CertificateSummaryList[].DomainName'
```

Leftover buckets and Elastic IPs should be cleaned up — Terraform will create new ones. **Leave old ACM certificates alone**; Terraform requests fresh ones and the old ones cause no harm.

> **Good news about DNS:** if the old ACM validation CNAME records are still in your zone, the new certificates will likely be issued almost immediately — ACM generates validation names deterministically per domain per account.

---

## 3. Bootstrap remote state

Local state is risky: it disappears with your laptop and can't be shared. Create the backend **before** anything else — note that this is done with the AWS CLI, not Terraform, precisely to avoid a chicken-and-egg problem.

```bash
REGION=<REGION>

aws s3api create-bucket --bucket fikom-tfstate --region $REGION \
  --create-bucket-configuration LocationConstraint=$REGION
aws s3api put-bucket-versioning --bucket fikom-tfstate \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket fikom-tfstate \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws s3api put-bucket-encryption --bucket fikom-tfstate \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws dynamodb create-table --table-name fikom-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region $REGION
```

Uncomment the backend block in `versions.tf`:

```hcl
backend "s3" {
  bucket         = "fikom-tfstate"
  key            = "ecs/production/terraform.tfstate"
  region         = "<REGION>"
  dynamodb_table = "fikom-tfstate-lock"
  encrypt        = true
}
```

```bash
cd terraform
terraform init
```

The state file itself doesn't need to exist — Terraform creates it on the first apply.

> Versioning on the state bucket matters: if state is corrupted or wrongly applied, you can restore a previous version. DynamoDB prevents two people applying at once.
>
> For a solo experiment you can skip this entirely and leave the backend block commented out; state will live locally.

---

## 4. Apply #1 — foundation

This creates the resources that the **manual steps depend on**: ACM certificates, ECR, both buckets, NAT + Elastic IP, and the private subnet.

```bash
terraform apply \
  -target=aws_acm_certificate.api \
  -target=aws_acm_certificate.frontend \
  -target=aws_ecr_repository.backend \
  -target=aws_s3_bucket.uploads \
  -target=aws_s3_bucket.frontend \
  -target=aws_nat_gateway.main \
  -target=aws_subnet.private
```

Terraform's warning about `-target` is expected here and intentional.

```bash
terraform output acm_validation_records   # two CNAMEs for DNS
terraform output nat_elastic_ip           # fixed IP to allow-list on the DB
```

> If secrets are configured as **data sources** (managed outside Terraform), make sure both secrets already exist before this point — data sources read, they don't create.

### Why two applies instead of one?

Apply everything at once and the ECS service is created while no image exists in ECR and the secrets are still empty. Tasks fail repeatedly (`CannotPullContainerError`, then `unable to pull secrets`), the service never stabilises, and you end up debugging what is really just an ordering problem.

---

## 5. Manual steps (run in parallel)

Four tasks that can all happen at the same time — build the image while DNS validation propagates.

### 5.1 ACM validation CNAME records

From `terraform output acm_validation_records`, add **two** CNAME records to your DNS zone (one for the API certificate, one for the frontend certificate).

```bash
dig +short _xxxxx.api.example.com CNAME
dig +short _yyyyy.app.example.com CNAME
```

### 5.2 Set the secret values

```bash
REGION=<REGION>

aws secretsmanager put-secret-value --region $REGION \
  --secret-id fikom/DATABASE_PASSWORD --secret-string 'YOUR_DB_PASSWORD'

aws secretsmanager put-secret-value --region $REGION \
  --secret-id fikom/JWT_SECRET --secret-string "$(openssl rand -base64 48)"
```

### 5.3 Allow-list the Elastic IP on the database server

```bash
terraform output nat_elastic_ip
```

This IP is **new** on every rebuild. On the database host:

```bash
# /etc/postgresql/<version>/main/pg_hba.conf
host    appdb    appuser    <ELASTIC_IP>/32    scram-sha-256

sudo systemctl reload postgresql
sudo ufw allow from <ELASTIC_IP> to any port 5432
```

Remove the previous allow-list entry at the same time so the rules don't accumulate.

> Skip this and the migration in step 8 will time out, and the service will never become healthy.

### 5.4 Push the first image to ECR

```bash
ACCOUNT_ID=<AWS_ACCOUNT_ID>
REGION=<REGION>
REPO="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/fikomecs"

aws ecr get-login-password --region $REGION | docker login --username AWS \
  --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

docker build --platform linux/amd64 -t fikomecs ./backend
docker tag fikomecs:latest "$REPO:latest"
docker push "$REPO:latest"
```

`--platform linux/amd64` is required when building on Apple Silicon — the task definition targets X86_64.

### Checkpoint

- [ ] Both ACM certificates report **ISSUED**
- [ ] Both secrets contain values
- [ ] The new Elastic IP is allow-listed on the database
- [ ] Image `:latest` exists in ECR

---

## 6. Apply #2 — compute & delivery

```bash
terraform plan
terraform apply
```

Terraform proceeds in this order: IAM roles → log group → security group rules → wait for ACM to be ISSUED → ALB, target group and listeners → ECS cluster and task definition → ECS service → CloudFront, OAC and bucket policy (the longest step, 10–15 minutes).

Verify the backend is alive:

```bash
aws ecs wait services-stable --cluster fikom-cluster \
  --services fikom-service --region <REGION>

TG=$(aws elbv2 describe-target-groups --names fikom-tg --region <REGION> \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --region <REGION> --target-group-arn $TG \
  --query 'TargetHealthDescriptions[].TargetHealth.State'   # -> "healthy"
```

> A target can be `healthy` before migrations have run — `/health` doesn't touch the database. The application is only fully functional after step 8.

```bash
terraform output
```

---

## 7. Application DNS

```bash
terraform output dns_records_to_create
```

| Host | Type | Value |
|---|---|---|
| `api` | CNAME | ALB DNS name (`fikom-alb-xxxx.<REGION>.elb.amazonaws.com`) |
| `app` | CNAME | CloudFront domain (`dxxxxxxxx.cloudfront.net`) |

> On a rebuild these values are **different** from before — ALB and CloudFront get new DNS names. **Replace** the old records rather than adding to them.

```bash
curl https://api.example.com/health
```

---

## 8. Database migration & seed

Both run as one-off ECS tasks — they start, do their work, and stop. No permanent resources.

Migrations are deliberately **not** run from the container entrypoint: with more than one replica, tasks would race each other to migrate.

```bash
REGION=<REGION>
SUBNET=$(terraform output -raw private_subnet_id)
SG=$(terraform output -raw task_security_group_id)
NET="awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}"
```

### 8.1 Migration

```bash
TASK_ARN=$(aws ecs run-task --cluster fikom-cluster --task-definition fikom-backend \
  --launch-type FARGATE --count 1 --network-configuration "$NET" \
  --overrides '{"containerOverrides":[{"name":"fikomecs","command":["node","scripts/migrate.js"]}]}' \
  --region $REGION --query 'tasks[0].taskArn' --output text)

aws ecs wait tasks-stopped --cluster fikom-cluster --tasks "$TASK_ARN" --region $REGION
aws ecs describe-tasks --cluster fikom-cluster --tasks "$TASK_ARN" --region $REGION \
  --query 'tasks[0].containers[0].exitCode'      # MUST be 0
```

Logs: `aws logs tail /ecs/fikom-backend --region $REGION --since 10m`

### 8.2 Seed the superadmin

Only run this **after** the migration exits 0 — the seed writes to a table the migration creates.

```bash
TASK_ARN=$(aws ecs run-task --cluster fikom-cluster --task-definition fikom-backend \
  --launch-type FARGATE --count 1 --network-configuration "$NET" \
  --overrides '{"containerOverrides":[{
    "name":"fikomecs",
    "command":["node","scripts/seed-superadmin.js"],
    "environment":[
      {"name":"SUPERADMIN_FULL_NAME","value":"Super Administrator"},
      {"name":"SUPERADMIN_USERNAME","value":"superadmin"},
      {"name":"SUPERADMIN_PASSWORD","value":"USE_A_STRONG_PASSWORD"},
      {"name":"SUPERADMIN_EMAIL","value":"admin@example.com"}
    ]}]}' \
  --region $REGION --query 'tasks[0].taskArn' --output text)

aws ecs wait tasks-stopped --cluster fikom-cluster --tasks "$TASK_ARN" --region $REGION
aws ecs describe-tasks --cluster fikom-cluster --tasks "$TASK_ARN" --region $REGION \
  --query 'tasks[0].containers[0].exitCode'
```

The seed is idempotent — safe to re-run.

> This password is visible in your shell history and in the task details. Since it only runs once that's acceptable, but treat it as sensitive and change it after first login.

---

## 9. Deploy the frontend

```bash
cd frontend
VITE_API_BASE_URL=https://api.example.com npm run build
aws s3 sync dist/ s3://fikom-frontend/ --delete
```

> `VITE_API_BASE_URL` is baked into the bundle at build time, not read at runtime. If the API URL changes, the frontend must be rebuilt.

If the distribution has already served content:

```bash
aws cloudfront create-invalidation \
  --distribution-id $(terraform output -raw cloudfront_distribution_id) --paths "/*"
```

---

## 10. Verification

```bash
curl https://api.example.com/health          # {"status":"ok"}
curl -I http://api.example.com/health        # 301 -> HTTPS
curl -I https://app.example.com              # 200
curl -I https://app.example.com/invoices     # 200 (SPA routing)
curl -I https://fikom-frontend.s3.<REGION>.amazonaws.com/index.html   # 403 (expected — bucket is private)
```

In the browser:

- [ ] `https://app.example.com` loads the application
- [ ] Superadmin login succeeds (proves API + database connectivity)
- [ ] File upload saves and the image renders (presigned URLs work)
- [ ] Refreshing on a sub-route doesn't 404
- [ ] No CORS errors in the console

---

## 11. Hand over to CI/CD

```bash
terraform output -json cicd_variables
```

Feed these into your pipeline — in particular `ECS_SUBNETS` and `ECS_SECURITY_GROUPS`. On a rebuild, `CLOUDFRONT_DIST_ID` is also new, so update both the pipeline and the `cloudfront:CreateInvalidation` resource ARN in the CI/CD IAM policy.

The boundary between the two tools is enforced by one block in `ecs.tf`:

```hcl
lifecycle {
  ignore_changes = [task_definition, desired_count]
}
```

Without it, the next `terraform apply` would drag the ECS service back to the task definition revision Terraform knows about — silently undoing the pipeline's most recent deploy.

---

## 12. Cheat sheet

```bash
# Step 2 — check for leftovers
aws secretsmanager list-secrets --region <REGION> --include-planned-deletion \
  --query "SecretList[?starts_with(Name,'fikom/')].{Name:Name,Deleted:DeletedDate}" --output table

# Step 3 — state backend
aws s3api create-bucket --bucket fikom-tfstate --region <REGION> \
  --create-bucket-configuration LocationConstraint=<REGION>
aws dynamodb create-table --table-name fikom-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region <REGION>

# Step 4 — apply #1
cd terraform && terraform init
terraform apply -target=aws_acm_certificate.api -target=aws_acm_certificate.frontend \
  -target=aws_ecr_repository.backend -target=aws_s3_bucket.uploads \
  -target=aws_s3_bucket.frontend -target=aws_nat_gateway.main -target=aws_subnet.private
terraform output acm_validation_records
terraform output nat_elastic_ip

# Step 5 — manual: DNS validation, secret values, allow-list EIP, push image

# Step 6 — apply #2
terraform apply && terraform output

# Step 7 — application DNS (api -> ALB, app -> CloudFront)
# Step 8 — migration + seed
# Step 9 — frontend
cd ../frontend && VITE_API_BASE_URL=https://api.example.com npm run build
aws s3 sync dist/ s3://fikom-frontend/ --delete
```

---

## 13. Troubleshooting

### `InvalidRequestException: ... scheduled for deletion`

An old secret is still in its recovery window. See [2.1](#21-secrets-still-inside-their-recovery-window) — delete it with `--force-delete-without-recovery`.

### `CNAMEAlreadyExists`

The alias is still claimed by an old CloudFront distribution. See [2.2](#22-a-cloudfront-distribution-that-hasnt-finished-deleting). The fastest fix is clearing the old distribution's alternate domain names rather than deleting it outright.

### `BucketAlreadyExists` / `BucketAlreadyOwnedByYou`

S3 bucket names are globally unique. Delete your old bucket first, or choose a different name in `terraform.tfvars` if the name is taken by another account.

### Apply hangs at `aws_acm_certificate_validation`

Waiting for ACM to verify the DNS records (45-minute timeout). Check the record name matches **exactly**, including a trailing dot if your DNS provider requires it.

```bash
terraform output acm_validation_records
dig +short _xxxxx.api.example.com CNAME
```

### `InvalidParameterException: The certificate must be in us-east-1`

The CloudFront certificate is using the wrong provider. Ensure `provider = aws.us_east_1` is set on **both** `aws_acm_certificate.frontend` and `aws_acm_certificate_validation.frontend`.

### Tasks keep getting replaced / target never healthy

```bash
TASK=$(aws ecs list-tasks --cluster fikom-cluster --desired-status STOPPED \
  --region <REGION> --query 'taskArns[0]' --output text)
aws ecs describe-tasks --cluster fikom-cluster --tasks $TASK --region <REGION> \
  --query 'tasks[0].{stopCode:stopCode,stoppedReason:stoppedReason,exit:containers[0].exitCode}'
```

| Symptom | Cause | Fix |
|---|---|---|
| `CannotPullContainerError` | No image pushed, or wrong architecture | Redo [5.4](#54-push-the-first-image-to-ecr) with `--platform linux/amd64` |
| `unable to pull secrets` | Secrets still empty | Redo [5.2](#52-set-the-secret-values) |
| `exitCode: 1`, logs show DB timeout | New Elastic IP not allow-listed | Redo [5.3](#53-allow-list-the-elastic-ip-on-the-database-server) |
| `exitCode: null` | Failed before the code ran | Read `stoppedReason`, not `exitCode` |

### Frontend returns 403 Access Denied

The OAC bucket policy isn't attached, or the distribution isn't `Deployed` yet:

```bash
aws s3api get-bucket-policy --bucket fikom-frontend --query Policy --output text
aws cloudfront get-distribution --id <DIST_ID> --query 'Distribution.Status'
```

Also confirm `default_root_object = "index.html"` and that custom error responses map **both** 403 and 404 to `/index.html` with status 200 — a private bucket returns 403, not 404, for a missing object.

### Login fails with a CORS error

`CORS_ORIGIN` in the task definition must exactly match the frontend origin. Terraform sets it from `frontend_domain`, so correct the value in `terraform.tfvars`, run `terraform apply`, then roll out a new revision:

```bash
aws ecs update-service --cluster fikom-cluster --service fikom-service \
  --task-definition fikom-backend --region <REGION>
```

### State is locked

```bash
terraform force-unlock <LOCK_ID>
```

Confirm no other apply is genuinely running first.

---

## After go-live

- [ ] Set `db_ssl = "true"` — enable SSL on PostgreSQL first, then change the value and apply
- [ ] Set `enable_deletion_protection = true` on the ALB in `alb.tf`
- [ ] Back up the uploads bucket regularly (versioning is enabled, but that isn't a backup)
- [ ] Add CloudWatch alarms: unhealthy targets, high CPU/memory, ALB error rate
- [ ] Update CI/CD values (`CLOUDFRONT_DIST_ID`, subnet, security group) — all of them change on a rebuild

### Rough running cost

| Component | ~USD/month |
|---|---|
| NAT Gateway | 32 + data processing |
| ALB | 16 + LCU |
| Fargate (0.5 vCPU / 1 GB, 1 task) | 18 |
| CloudFront / S3 / ECR / Secrets Manager | 3–8 |
| **Total** | **~70–80** |

The NAT Gateway is the largest line item. It is the price of a stable egress IP for as long as PostgreSQL lives outside AWS — moving the database to RDS would remove that requirement entirely.

*Prices are indicative for `ap-southeast-1` and change over time; check the AWS Pricing Calculator for current figures.*
