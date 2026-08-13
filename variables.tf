# ------------------------------------------------------------------------------
# Sovereign Vault: KMS & IAM Variables
# ------------------------------------------------------------------------------
variable "environment" {
  type        = string
  default     = "prod"
  description = "環境識別子 (prod / staging / dev)"
}

variable "enable_key_rotation" {
  type        = bool
  default     = true
  description = "KMS自動キーローテーションの有効化フラグ"
}

variable "trusted_cross_account_arns" {
  type        = list(string)
  description = "KMSキーアクセスを許可するクロスアカウントのARNリスト"
  default = [
    "arn:aws:iam::123456789012:root" # ※後日、実際の顧客アカウントIDに変更する
  ]
}

variable "cross_account_external_id" {
  type        = string
  description = "sts:AssumeRole時のConfused Deputy攻撃防止用ExternalID"
  default     = "SovereignVaultExternalID-2026"
}