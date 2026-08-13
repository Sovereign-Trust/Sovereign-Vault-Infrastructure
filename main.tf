terraform {
  required_version = ">= 1.5.0"
  backend "s3" {
    bucket         = "sovereign-vault-state-bucket"
    key            = "sovereign-vault/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" { region = "ap-northeast-1" }
data "aws_caller_identity" "current" {}


resource "random_id" "vault_id" { byte_length = 4 }

resource "aws_s3_bucket" "primary" {
  bucket              = "sovereign-vault-tokyo-${random_id.vault_id.hex}"
  object_lock_enabled = true
}

resource "aws_s3_bucket_versioning" "primary_versioning" {
  bucket = aws_s3_bucket.primary.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "primary_sse" {
  bucket = aws_s3_bucket.primary.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.vault_cross_account_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "primary_block" {
  bucket                  = aws_s3_bucket.primary.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_object_lock_configuration" "primary_lock" {
  bucket = aws_s3_bucket.primary.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 3650
    }
  }
}

resource "aws_s3_bucket_policy" "primary_bucket_policy" {
  bucket = aws_s3_bucket.primary.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "EnforceTLSRequestsOnly",
        Effect    = "Deny",
        Principal = "*",
        Action    = "s3:*",
        Resource  = [aws_s3_bucket.primary.arn, "${aws_s3_bucket.primary.arn}/*"],
        Condition = { Bool = { "aws:SecureTransport" : "false" } }
      }
    ]
  })
}

resource "aws_s3_bucket" "log_bucket" {
  bucket = "sovereign-vault-logs-${random_id.vault_id.hex}"
}

# パブリックアクセスブロック（ログバケットのセキュリティ強化）
resource "aws_s3_bucket_public_access_block" "log_bucket_block" {
  bucket                  = aws_s3_bucket.log_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ライフサイクルルールの追加（コスト最適化）
resource "aws_s3_bucket_lifecycle_configuration" "log_bucket_lifecycle" {
  bucket = aws_s3_bucket.log_bucket.id

  rule {
    id     = "archive-and-delete-logs"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "log_bucket_policy" {
  bucket = aws_s3_bucket.log_bucket.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Sid = "AWSCloudTrailAclCheck", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:GetBucketAcl", Resource = aws_s3_bucket.log_bucket.arn, Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } } },
      { Sid = "AWSCloudTrailWrite", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.log_bucket.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*", Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control", "aws:SourceAccount" = data.aws_caller_identity.current.account_id } } }
    ]
  })
}

resource "aws_cloudtrail" "vault_trail" {
  name                          = "sovereign-vault-trail-${random_id.vault_id.hex}"
  s3_bucket_name                = aws_s3_bucket.log_bucket.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  depends_on                    = [aws_s3_bucket_policy.log_bucket_policy]
  event_selector {
    read_write_type           = "All"
    include_management_events = true
    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.primary.arn}/"]
    }
  }
}
# Sovereign Vault 本体バケットのライフサイクルルール（コスト最適化）
resource "aws_s3_bucket_lifecycle_configuration" "primary_lifecycle" {
  bucket = aws_s3_bucket.primary.id

  rule {
    id     = "archive-to-glacier-after-90-days"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}
# ------------------------------------------------------------------------------
# 1. Sovereign Vault Master Key (KMS CMK)
# ------------------------------------------------------------------------------
resource "random_id" "kms_suffix" {
  byte_length = 4
}

resource "aws_kms_key" "vault_cross_account_key" {
  description             = "Sovereign Vault Cross-Account CMK (${var.environment})"
  enable_key_rotation     = var.enable_key_rotation
  deletion_window_in_days = 30
  multi_region            = true
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # ホストアカウント管理者へのキーフル管理権限（ポリシー変更・監査権限）
      {
        Sid    = "AllowHostAccountAdminManagement",
        Effect = "Allow",
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        Action   = "kms:*",
        Resource = "*"
      },
      # クロスアカウントエンティティに対する暗号化・復号操作の委任
      {
        Sid    = "AllowCrossAccountCryptoOperations",
        Effect = "Allow",
        Principal = {
          AWS = var.trusted_cross_account_arns
        },
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ],
        Resource = "*"
      },
      # 暗号シュレッディング（鍵削除・無効化）の明示的拒否
      {
        Sid       = "PreventCryptoShredding",
        Effect    = "Deny",
        Principal = "*",
        Action = [
          "kms:ScheduleKeyDeletion",
          "kms:DisableKey"
        ],
        Resource = "*"
      }
    ]
  })
  tags = {
    Project     = "SovereignVault"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# KMSエイリアスの作成
resource "aws_kms_alias" "vault_cross_account_key_alias" {
  name          = "alias/sovereign-vault-cross-account-${random_id.kms_suffix.hex}"
  target_key_id = aws_kms_key.vault_cross_account_key.key_id
}

# ------------------------------------------------------------------------------
# 2. クロスアカウント連携用 IAM Role & Policy (ホストアカウント側)
# ------------------------------------------------------------------------------
# クロスアカウントアクセス用 AssumeRole
resource "aws_iam_role" "sovereign_vault_cross_account_role" {
  name        = "SovereignVaultCrossAccountRole-${var.environment}"
  description = "Sovereign Vaultのクロスアカウントアクセス用IAMロール"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          AWS = var.trusted_cross_account_arns
        },
        Action = "sts:AssumeRole",
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.cross_account_external_id
          }
        }
      }
    ]
  })
}

# 最小権限KMS利用ポリシー
resource "aws_iam_policy" "sovereign_vault_kms_least_privilege_policy" {
  name        = "SovereignVaultKMSLeastPrivilegePolicy-${var.environment}"
  description = "KMSキーの暗号化・復号およびデータキー生成のみを許可する最小権限ポリシー"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowKMSOperations",
        Effect = "Allow",
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ],
        Resource = aws_kms_key.vault_cross_account_key.arn
      }
    ]
  })
}

# ロールへポリシーをアタッチ
resource "aws_iam_role_policy_attachment" "attach_sovereign_vault_kms_policy" {
  role       = aws_iam_role.sovereign_vault_cross_account_role.name
  policy_arn = aws_iam_policy.sovereign_vault_kms_least_privilege_policy.arn
}