#!/usr/bin/env bash
# =============================================================================
# Parameter Store 登録スクリプト (ADOT Collector 設定 / CloudWatch Agent 設定 / DB パスワード)
# 実行前に AWS_REGION / APP_NAME / ENV を環境に合わせて設定すること。
# =============================================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:?e.g. ap-northeast-1}"
APP_NAME="${APP_NAME:?e.g. myapp}"
ENV="${ENV:?e.g. prod}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. ADOT Collector 設定 (YAML, 秘密情報を含まないため String) -------------
aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --name "/${APP_NAME}/${ENV}/adot-collector-config" \
  --type String \
  --tier Intelligent-Tiering \
  --value "file://${SCRIPT_DIR}/adot-collector-config.yaml" \
  --overwrite

# --- 2. CloudWatch Agent 設定 (JSON, 秘密情報を含まないため String) ------------
aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --name "/${APP_NAME}/${ENV}/cwagent-config" \
  --type String \
  --tier Intelligent-Tiering \
  --value "file://${SCRIPT_DIR}/cwagent-config.json" \
  --overwrite

# --- 3. DB パスワード (秘密情報なので SecureString + KMS CMK) -------------------
#     値は対話的に渡すか CI のシークレットから注入する (コマンド履歴に残さない)
read -r -s -p "DB password: " DB_PASSWORD_VALUE; echo
aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --name "/${APP_NAME}/${ENV}/db/password" \
  --type SecureString \
  --key-id "alias/${APP_NAME}-${ENV}-ssm" \
  --value "${DB_PASSWORD_VALUE}" \
  --overwrite
unset DB_PASSWORD_VALUE

# --- 4. 登録結果の確認 ----------------------------------------------------------
aws ssm get-parameter --region "${AWS_REGION}" \
  --name "/${APP_NAME}/${ENV}/adot-collector-config" \
  --query 'Parameter.{Name:Name,Version:Version,Type:Type}' --output table
aws ssm get-parameter --region "${AWS_REGION}" \
  --name "/${APP_NAME}/${ENV}/cwagent-config" \
  --query 'Parameter.{Name:Name,Version:Version,Type:Type}' --output table

echo "NOTE: パラメータ更新後は ECS サービスの新デプロイ (--force-new-deployment) が必要です。"
echo "      secrets はタスク起動時にのみ解決されるため、既存タスクには反映されません。"
