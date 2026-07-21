# Sovereign Vault Infrastructure (IaC)

## 概要
本リポジトリは、エンタープライズにおける法的証拠保全要件（WORMモデル）を満たすため、AWSとTerraformを用いて構築された、完全不変（Immutable）かつ改ざん不可能なセキュア・ストレージのIaC（Infrastructure as Code）アーキテクチャです。

ランサムウェア攻撃、内部犯行、および特権管理者のアカウント乗っ取りを想定した、ゼロトラスト思想に基づくデータ防衛ソリューションとして設計されています。

## コア・セキュリティ・アーキテクチャ

### 1. 絶対不変ストレージ (Immutable Storage by WORM)
* **S3 Object Lock (COMPLIANCE Mode):** データの保存期間を3650日間（10年間）にハードコード。この設定は、AWSルートアカウント、およびAWSサポートチームであっても変更・削除・短縮は不可能です。
* **暗号シュレッディング対策 (Anti-Crypto-Shredding):** KMSカスタマーマネージドキー（CMK）において、キーの無効化（`DisableKey`）および削除スケジューリング（`ScheduleKeyDeletion`）をIAMポリシーの明示的拒否（Deny）により完全ブロック。データの暗号鍵を破壊して実質的に読み取り不能にする攻撃を未然に防ぎます。

### 2. データ完全性と防御ライン (Data Integrity & Perimeter Defense)
* **TLS 1.2/1.3の強制:** プレーンなHTTP通信によるデータ転送をS3バケットポリシーで明示的に拒否。
* **ポリシー改ざん防止:** バケットポリシー自体の削除・変更操作（`DeleteBucketPolicy` / `PutBucketPolicy`）を拒否し、設定のドリフト（乖離）やバックドアの作成を防止。
* **デフォルト暗号化の強制:** 全てのオブジェクトに対し、AWS KMSを用いたサーバーサイド暗号化（SSE-KMS）を強制。

### 3. 不可逆な監査ログ (Immutable Audit Trails)
* **AWS CloudTrailによるデータ監視:** S3バケットに対するすべてのデータ操作（Read/Write/Deleteイベント）を、完全に独立したログ専用バケット（`log_bucket`）へリアルタイムに転送。
* **ログファイル検証の有効化:** ログが転送後に改ざんされていないかを暗号学的に検証する機能を有効化（`enable_log_file_validation = true`）。

## 技術スタック
* **IaC:** Terraform (>= 1.5.0)
* **Cloud:** AWS (S3, KMS, CloudTrail, IAM)
* **OS環境:** Amazon Linux 2023 (全自動デプロイスクリプト対応)

## 🚀 開発ロードマップ (Development Roadmap)
* [x] **Phase 1: コアストレージの構築 (Done)**
  * S3 Object Lockによる10年間のデータ不変性の担保
  * KMSキーによる暗号化と削除制限ポリシーの実装
  * CloudTrailによるAPI監査ログの取得とログバケットへの隔離保護
* [x] **Phase 2: 実運用向けIaC最適化 (Done)**
  * Terraform State (.tfstate) のS3 + DynamoDBによるセキュアなリモート管理およびステートロック機能の実装
  * ライフサイクルルールによる、一定期間経過後のGlacier Flexible Retrievalへの自動移行（ストレージコストの最適化）
* [ ] **Phase 3: グローバル・ディザスタリカバリ (Planned)**
  * BCR（事業継続要件）を満たすための、クロスリージョン・レプリケーションの自動化
  * USリージョンを含めたマルチリージョン暗号鍵（Multi-Region KMS Key）の本格運用
