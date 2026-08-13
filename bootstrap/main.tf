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