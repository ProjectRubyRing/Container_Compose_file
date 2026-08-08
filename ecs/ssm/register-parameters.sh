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

# --- CloudWatch Agent 設定の登録方式 -------------------------------------------
# 既定 (0) は従来どおり cwagent-config を String 1 本で登録する。
#
# 1 にすると「SecureString + 主設定/追加設定の 2 本」方式に切り替わり、
# ECS タスク定義の secrets CW_CONFIG_CONTENT / CW_CONFIG_CONTENT_MID に対応する。
# こちらは terraform/ でも同じものを登録できる (Terraform で管理する場合は
# 二重管理を避けるため、このスクリプトでは登録しないこと = 既定の 0 のままにする)。
#   CWAGENT_SECURESTRING=1 KMS_KEY_ALIAS=alias/myapp-prod-ssm ./register-parameters.sh
# 詳細は ../../docs/CWAGENT-SSM-CONFIG.md を参照。
CWAGENT_SECURESTRING="${CWAGENT_SECURESTRING:-0}"
KMS_KEY_ALIAS="${KMS_KEY_ALIAS:-alias/${APP_NAME}-${ENV}-ssm}"

# --- 1. ADOT Collector 設定 (YAML, 秘密情報を含まないため String) -------------
aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --name "/${APP_NAME}/${ENV}/adot-collector-config" \
  --type String \
  --tier Intelligent-Tiering \
  --value "file://${SCRIPT_DIR}/adot-collector-config.yaml" \
  --overwrite

# --- 2. CloudWatch Agent 設定 --------------------------------------------------
# タスク定義の secrets CW_CONFIG_CONTENT に注入され、エージェントがデフォルトロードする。
if [[ "${CWAGENT_SECURESTRING}" == "1" ]]; then
  # SecureString 方式: 主設定 (CW_CONFIG_CONTENT) + 追加設定 (CW_CONFIG_CONTENT_MID)
  # 追加設定はエージェントが素のままでは読まないため、taskdef 側の entryPoint で
  # /etc/cwagentconfig へ materialize する (ecs/taskdef.json 参照)。
  aws ssm put-parameter \
    --region "${AWS_REGION}" \
    --name "/${APP_NAME}/${ENV}/cwagent-config" \
    --type SecureString \
    --key-id "${KMS_KEY_ALIAS}" \
    --tier Intelligent-Tiering \
    --value "file://${SCRIPT_DIR}/cwagent-config.json" \
    --overwrite

  aws ssm put-parameter \
    --region "${AWS_REGION}" \
    --name "/${APP_NAME}/${ENV}/cwagent-config-mid" \
    --type SecureString \
    --key-id "${KMS_KEY_ALIAS}" \
    --tier Intelligent-Tiering \
    --value "file://${SCRIPT_DIR}/cwagent-config-mid.json" \
    --overwrite
else
  # 従来方式 (JSON, 秘密情報を含まないため String)
  aws ssm put-parameter \
    --region "${AWS_REGION}" \
    --name "/${APP_NAME}/${ENV}/cwagent-config" \
    --type String \
    --tier Intelligent-Tiering \
    --value "file://${SCRIPT_DIR}/cwagent-config.json" \
    --overwrite
fi

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
if [[ "${CWAGENT_SECURESTRING}" == "1" ]]; then
  aws ssm get-parameter --region "${AWS_REGION}" \
    --name "/${APP_NAME}/${ENV}/cwagent-config-mid" \
    --query 'Parameter.{Name:Name,Version:Version,Type:Type}' --output table
fi

echo "NOTE: パラメータ更新後は ECS サービスの新デプロイ (--force-new-deployment) が必要です。"
echo "      secrets はタスク起動時にのみ解決されるため、既存タスクには反映されません。"
