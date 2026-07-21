# -----------------------------------------------------------
# Phase 4: Data Exfiltration Defense (WIP)
# -----------------------------------------------------------

# 1. VPC Endpoint (S3 Gateway)
resource "aws_vpc_endpoint" "s3_endpoint" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.main.id]

  tags = {
    Name = "sovereign-vault-s3-vpce"
  }
}

# 2. S3 Bucket Policy (VPC Endpoint Restriction)
resource "aws_s3_bucket_policy" "restrict_to_vpce" {
  bucket = aws_s3_bucket.sovereign_vault.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyAccessOutsideVPCE"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource = [
          "${aws_s3_bucket.sovereign_vault.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:sourceVpce" = aws_vpc_endpoint.s3_endpoint.id
          }
        }
      }
    ]
  })
}

# 3. Amazon GuardDuty (S3 Protection)
resource "aws_guardduty_detector" "main" {
  enable = true
  datasources {
    s3_logs {
      enable = true
    }
  }
  tags = {
    Name = "sovereign-vault-guardduty"
  }
}

# 4. Amazon Macie
resource "aws_macie2_account" "main" {
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  status                       = "ENABLED"
}