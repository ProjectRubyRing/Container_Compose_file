# =============================================================================
# 出力 (登録した Parameter Store の情報を確認するためのもの)
# -----------------------------------------------------------------------------
#   terraform output parameter_summary           … 登録結果の一覧
#   terraform output -raw verify_commands        … AWS CLI での確認コマンド
#   terraform output -raw ecs_taskdef_secrets    … taskdef へ貼る secrets ブロック
#   terraform output -raw iam_policy_resources   … 実行ロールへ足す Resource ARN
#   terraform output -raw next_steps             … ECS への反映手順
#
# SecureString の**値そのものは出力しない**。同一性の確認には sha256 を使い、
# 中身を見たいときは verify_commands の get-parameter --with-decryption を使う。
# =============================================================================

locals {
  # 登録したパラメータを 1 つのリストにまとめ、各出力はここから組み立てる
  registered = concat(
    [{
      env_var      = "CW_CONFIG_CONTENT"
      role         = "デフォルトロードされる主設定"
      name         = aws_ssm_parameter.cwagent_config.name
      arn          = aws_ssm_parameter.cwagent_config.arn
      type         = aws_ssm_parameter.cwagent_config.type
      tier         = aws_ssm_parameter.cwagent_config.tier
      version      = aws_ssm_parameter.cwagent_config.version
      kms_key_id   = coalesce(local.effective_kms_key_id, "alias/aws/ssm (AWS managed)")
      value_bytes  = length(local.cwagent_config_json)
      value_sha256 = sha256(local.cwagent_config_json)
      source       = var.cwagent_config_json != null ? "(var.cwagent_config_json)" : var.cwagent_config_json_path
    }],
    var.register_mid_parameter ? [{
      env_var      = "CW_CONFIG_CONTENT_MID"
      role         = "追加設定 (taskdef の entryPoint でマージされる)"
      name         = aws_ssm_parameter.cwagent_config_mid[0].name
      arn          = aws_ssm_parameter.cwagent_config_mid[0].arn
      type         = aws_ssm_parameter.cwagent_config_mid[0].type
      tier         = aws_ssm_parameter.cwagent_config_mid[0].tier
      version      = aws_ssm_parameter.cwagent_config_mid[0].version
      kms_key_id   = coalesce(local.effective_kms_key_id, "alias/aws/ssm (AWS managed)")
      value_bytes  = length(local.cwagent_config_mid_json)
      value_sha256 = sha256(local.cwagent_config_mid_json)
      source       = var.cwagent_config_mid_json != null ? "(var.cwagent_config_mid_json)" : var.cwagent_config_mid_json_path
    }] : [],
  )
}

output "parameter_summary" {
  description = "登録した Parameter Store パラメータの一覧 (環境変数名 / 名前 / ARN / 型 / ティア / バージョン / サイズ / sha256)"
  value       = { for p in local.registered : p.env_var => p }
}

output "parameter_names" {
  description = "登録したパラメータ名のリスト"
  value       = [for p in local.registered : p.name]
}

output "parameter_arns" {
  description = "登録したパラメータの ARN リスト"
  value       = [for p in local.registered : p.arn]
}

output "kms_key_arn" {
  description = "create_kms_key = true のときに作成した CMK の ARN (未作成なら null = AWS 管理キーを使用)"
  value       = var.create_kms_key ? aws_kms_key.ssm[0].arn : null
}

# --- ECS タスク定義へ貼り付ける secrets ブロック --------------------------------
output "ecs_taskdef_secrets" {
  description = "ecs/taskdef.json の cwagent コンテナへそのまま貼れる secrets 配列 (JSON)"
  value = jsonencode([
    for p in local.registered : {
      name      = p.env_var
      valueFrom = p.arn
    }
  ])
}

# --- IAM 実行ロールへ足す Resource ---------------------------------------------
output "iam_policy_resources" {
  description = "タスク実行ロールの ssm:GetParameters へ追加する Resource (ecs/iam/task-execution-role-policy.json)"
  value       = join("\n", [for p in local.registered : format("\"%s\",", p.arn)])
}

# --- AWS CLI での確認コマンド ---------------------------------------------------
output "verify_commands" {
  description = "登録内容を AWS CLI で確認するコマンド (terraform output -raw verify_commands で表示)"
  value = join("\n", concat(
    [
      "# 1) 登録されたメタデータ (型 / ティア / バージョン / KMS キー)",
      format(
        "aws ssm describe-parameters --region %s --parameter-filters 'Key=Name,Option=BeginsWith,Values=%s' --query 'Parameters[].{Name:Name,Type:Type,Tier:Tier,Version:Version,KeyId:KeyId,Modified:LastModifiedDate}' --output table",
        var.aws_region, local.parameter_prefix,
      ),
      "",
      "# 2) 復号した値 (= ECS が環境変数へ入れる JSON そのもの)",
    ],
    [
      for p in local.registered : format(
        "aws ssm get-parameter --region %s --name '%s' --with-decryption --query 'Parameter.Value' --output text   # → %s",
        var.aws_region, p.name, p.env_var,
      )
    ],
    [
      "",
      "# 3) 値が Terraform の管理内容と一致するか (sha256 の突き合わせ)",
    ],
    flatten([
      for p in local.registered : [
        format(
          "aws ssm get-parameter --region %s --name '%s' --with-decryption --query 'Parameter.Value' --output text | tr -d '\\n' | sha256sum",
          var.aws_region, p.name,
        ),
        format("#   期待値 (%s): %s", p.env_var, p.value_sha256),
      ]
    ]),
  ))
}

# --- 反映手順 -------------------------------------------------------------------
output "next_steps" {
  description = "パラメータ更新を ECS へ反映する手順とローカル検証の入口"
  value = join("\n", [
    "# secrets はタスク起動時にしか解決されない。パラメータを更新しただけでは",
    "# 既存タスクには反映されないため、新しいタスクを起動すること:",
    "aws ecs update-service --cluster <ECS_CLUSTER_NAME> --service <ECS_SERVICE_NAME> \\",
    format("  --task-definition %s-%s-task --force-new-deployment --region %s", var.app_name, var.env, var.aws_region),
    "",
    "# 同じ JSON の動作をローカル compose で先に確認する場合:",
    "#   compose/cwagent/ssm/cwagent-config.json     (= CW_CONFIG_CONTENT)",
    "#   compose/cwagent/ssm/cwagent-config-mid.json (= CW_CONFIG_CONTENT_MID)",
    "docker compose --profile ssm-config up -d cwagent-ssm && ./verify-cwagent-ssm.sh",
  ])
}
