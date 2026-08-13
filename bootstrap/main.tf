terraform {
  backend "s3" {
    bucket         = "sovereign-vault-state-bucket-9999"
    key            = "bootstrap/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "sovereign-vault-state-lock"
    encrypt        = true
  }
}
provider "aws" {
  region = "ap-northeast-1"
}

# 1. ステート保存用のS3バケット
resource "aws_s3_bucket" "terraform_state" {
  bucket = "sovereign-vault-state-bucket-9999" # ← ここを必ず変更する
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 2. ステートロック用のDynamoDBテーブル
resource "aws_dynamodb_table" "terraform_lock" {
  name         = "sovereign-vault-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
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
        Sid       = "AllowHostAccountAdminManagement",
        Effect    = "Allow",
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        Action    = "kms:*",
        Resource  = "*"
      },
      # クロスアカウントエンティティに対する暗号化・復号操作の委任
      {
        Sid       = "AllowCrossAccountCryptoOperations",
        Effect    = "Allow",
        Principal = {
          AWS = var.trusted_cross_account_arns
        },
        Action    = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ],
        Resource  = "*"
      },
      # 暗号シュレッディング（鍵削除・無効化）の明示的拒否
      {
        Sid       = "PreventCryptoShredding",
        Effect    = "Deny",
        Principal = "*",
        Action    = [
          "kms:ScheduleKeyDeletion",
          "kms:DisableKey"
        ],
        Resource  = "*"
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
        Effect    = "Allow",
        Principal = {
          AWS = var.trusted_cross_account_arns
        },
        Action    = "sts:AssumeRole",
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
        Sid      = "AllowKMSOperations",
        Effect   = "Allow",
        Action   = [
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