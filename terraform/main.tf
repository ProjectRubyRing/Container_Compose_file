# =============================================================================
# CloudWatch Agent 設定を SSM Parameter Store へ SecureString で登録する
# -----------------------------------------------------------------------------
#   /<app_name>/<env>/cwagent-config      → ECS taskdef の secrets CW_CONFIG_CONTENT
#   /<app_name>/<env>/cwagent-config-mid  → ECS taskdef の secrets CW_CONFIG_CONTENT_MID
#
# 登録した値は ECS エージェントがタスク起動時に取得・復号し、環境変数として
# cwagent コンテナへ渡す。cwagent 側は taskdef の entryPoint で /etc/cwagentconfig/ へ
# materialize し、CloudWatch Agent がそれらをマージして実効設定にする。
# (ローカル compose での等価な偽装は docs/CWAGENT-SSM-CONFIG.md を参照)
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  parameter_prefix = "/${var.app_name}/${var.env}"

  cwagent_config_parameter_name = coalesce(
    var.cwagent_config_parameter_name,
    "${local.parameter_prefix}/cwagent-config",
  )
  cwagent_config_mid_parameter_name = coalesce(
    var.cwagent_config_mid_parameter_name,
    "${local.parameter_prefix}/cwagent-config-mid",
  )

  # 生の JSON。変数で直接渡されなければモジュール相対のファイルから読む。
  # try() で包むのは、*_json を直接渡したときに既定パスのファイルが無くても
  # 読み込みエラーにしないため。
  cwagent_config_raw = coalesce(
    var.cwagent_config_json,
    try(file("${path.module}/${var.cwagent_config_json_path}"), ""),
  )
  cwagent_config_mid_raw = coalesce(
    var.cwagent_config_mid_json,
    try(file("${path.module}/${var.cwagent_config_mid_json_path}"), ""),
  )

  # ecs/ssm/*.json はリポジトリ内ではプレースホルダーのままなので実値へ置換する
  # (置換規則は taskdef.json / IAM ポリシーと同じ)。
  # 独自のプレースホルダーを使う場合は、置換済みの JSON を
  # var.cwagent_config_json / var.cwagent_config_mid_json で直接渡すこと。
  cwagent_config_substituted = replace(
    replace(
      replace(
        replace(local.cwagent_config_raw, "<APP_NAME>", var.app_name),
        "<ENV>", var.env,
      ),
      "<AWS_REGION>", var.aws_region,
    ),
    "<ACCOUNT_ID>", data.aws_caller_identity.current.account_id,
  )

  cwagent_config_mid_substituted = replace(
    replace(
      replace(
        replace(local.cwagent_config_mid_raw, "<APP_NAME>", var.app_name),
        "<ENV>", var.env,
      ),
      "<AWS_REGION>", var.aws_region,
    ),
    "<ACCOUNT_ID>", data.aws_caller_identity.current.account_id,
  )

  # jsondecode → jsonencode で「JSON として妥当か」を plan 時に検証しつつ
  # 1 行へ最小化する。パラメータのサイズ上限 (Standard 4KB) に効くうえ、
  # ECS が環境変数へ入れるのも 1 本の文字列なので、この形が本番と同じ姿になる。
  cwagent_config_json     = jsonencode(jsondecode(local.cwagent_config_substituted))
  cwagent_config_mid_json = jsonencode(jsondecode(local.cwagent_config_mid_substituted))

  # Standard は 4096 バイト、Advanced は 8192 バイトが上限
  parameter_size_limit = var.parameter_tier == "Standard" ? 4096 : 8192
}

# --- SecureString 用の KMS キー (任意) ---------------------------------------
# 既定では作らず AWS 管理キー (alias/aws/ssm) を使う。
# ecs/iam/task-execution-role-policy.json のように CMK を条件付きで許可する構成に
# そろえたい場合は create_kms_key = true にするか、既存キーを kms_key_id で渡す。
resource "aws_kms_key" "ssm" {
  count = var.create_kms_key ? 1 : 0

  description             = "SSM SecureString key for ${var.app_name}/${var.env}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_key_deletion_window_in_days
}

resource "aws_kms_alias" "ssm" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${var.app_name}-${var.env}-ssm"
  target_key_id = aws_kms_key.ssm[0].key_id
}

locals {
  # null を渡すと aws_ssm_parameter は AWS 管理キー (alias/aws/ssm) を使う
  effective_kms_key_id = var.create_kms_key ? aws_kms_alias.ssm[0].name : var.kms_key_id
}

# --- 主設定 (CW_CONFIG_CONTENT) ----------------------------------------------
resource "aws_ssm_parameter" "cwagent_config" {
  name = local.cwagent_config_parameter_name
  # SecureString にすると保存時に KMS で暗号化される。ECS の secrets 経由なら
  # 復号はタスク実行ロールが行うため、値がタスク定義やコンソールの
  # 環境変数一覧に平文で残らない。
  type        = "SecureString"
  key_id      = local.effective_kms_key_id
  tier        = var.parameter_tier
  value       = local.cwagent_config_json
  description = "CloudWatch Agent config loaded by default via CW_CONFIG_CONTENT (${var.app_name}/${var.env})"

  tags = merge(var.tags, {
    "cwagent-config-role" = "default"
    "injected-as"         = "CW_CONFIG_CONTENT"
  })

  # apply して AWS 側に弾かれる前に plan で気づけるようにする
  lifecycle {
    precondition {
      condition     = length(local.cwagent_config_raw) > 0
      error_message = "CW_CONFIG_CONTENT 用の JSON が空です。cwagent_config_json を指定するか、cwagent_config_json_path (既定: ../ecs/ssm/cwagent-config.json) を確認してください。"
    }

    precondition {
      condition = length(local.cwagent_config_json) <= local.parameter_size_limit
      error_message = format(
        "CW_CONFIG_CONTENT 用の JSON が %d バイトで、tier=%s の上限 %d バイトを超えています。parameter_tier を Advanced か Intelligent-Tiering にするか、設定を CW_CONFIG_CONTENT_MID 側へ分割してください。",
        length(local.cwagent_config_json),
        var.parameter_tier,
        local.parameter_size_limit,
      )
    }
  }
}

# --- 追加設定 (CW_CONFIG_CONTENT_MID) ----------------------------------------
# 実エージェントが自動で読むのは CW_CONFIG_CONTENT だけなので、この値を効かせるには
# taskdef 側の entryPoint による materialize が必要 (ecs/taskdef.json 参照)。
resource "aws_ssm_parameter" "cwagent_config_mid" {
  count = var.register_mid_parameter ? 1 : 0

  name        = local.cwagent_config_mid_parameter_name
  type        = "SecureString"
  key_id      = local.effective_kms_key_id
  tier        = var.parameter_tier
  value       = local.cwagent_config_mid_json
  description = "Additional CloudWatch Agent config merged via CW_CONFIG_CONTENT_MID (${var.app_name}/${var.env})"

  tags = merge(var.tags, {
    "cwagent-config-role" = "additional"
    "injected-as"         = "CW_CONFIG_CONTENT_MID"
  })

  lifecycle {
    precondition {
      condition     = length(local.cwagent_config_mid_raw) > 0
      error_message = "CW_CONFIG_CONTENT_MID 用の JSON が空です。cwagent_config_mid_json を指定するか、cwagent_config_mid_json_path (既定: ../ecs/ssm/cwagent-config-mid.json) を確認してください。登録が不要なら register_mid_parameter = false にしてください。"
    }

    precondition {
      condition = length(local.cwagent_config_mid_json) <= local.parameter_size_limit
      error_message = format(
        "CW_CONFIG_CONTENT_MID 用の JSON が %d バイトで、tier=%s の上限 %d バイトを超えています。parameter_tier を Advanced か Intelligent-Tiering にしてください。",
        length(local.cwagent_config_mid_json),
        var.parameter_tier,
        local.parameter_size_limit,
      )
    }
  }
}
