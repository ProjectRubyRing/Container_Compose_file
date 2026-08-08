# =============================================================================
# 入力変数
#   最低限 app_name / env を与えれば動く。設定 JSON は既定でリポジトリ内の
#   ecs/ssm/*.json を読み込むため、通常は path 系を指定する必要はない。
# =============================================================================

variable "aws_region" {
  description = "パラメータを登録するリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "app_name" {
  description = "アプリ名。パラメータ名 /<app_name>/<env>/... に使う (taskdef の <APP_NAME> と一致させる)"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+$", var.app_name))
    error_message = "app_name には英数字と . _ - のみ使用できます。"
  }
}

variable "env" {
  description = "環境名。パラメータ名 /<app_name>/<env>/... に使う (taskdef の <ENV> と一致させる)"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+$", var.env))
    error_message = "env には英数字と . _ - のみ使用できます。"
  }
}

# --- 登録するパラメータ名 -----------------------------------------------------
# 既定はタスク定義 (ecs/taskdef.json) の valueFrom と一致させてある。

variable "cwagent_config_parameter_name" {
  description = "CW_CONFIG_CONTENT に注入する主設定のパラメータ名。null なら /<app_name>/<env>/cwagent-config"
  type        = string
  default     = null
}

variable "cwagent_config_mid_parameter_name" {
  description = "CW_CONFIG_CONTENT_MID に注入する追加設定のパラメータ名。null なら /<app_name>/<env>/cwagent-config-mid"
  type        = string
  default     = null
}

# --- 登録する JSON の中身 -----------------------------------------------------
# *_json を指定するとその文字列を、指定しなければ *_json_path のファイルを使う。
# パスは **このモジュールディレクトリからの相対パス**。

variable "cwagent_config_json" {
  description = "CW_CONFIG_CONTENT に登録する JSON 文字列。null ならファイル (cwagent_config_json_path) から読む"
  type        = string
  default     = null
}

variable "cwagent_config_json_path" {
  description = "CW_CONFIG_CONTENT に登録する JSON ファイル (モジュールからの相対パス)"
  type        = string
  default     = "../ecs/ssm/cwagent-config.json"
}

variable "cwagent_config_mid_json" {
  description = "CW_CONFIG_CONTENT_MID に登録する JSON 文字列。null ならファイル (cwagent_config_mid_json_path) から読む"
  type        = string
  default     = null
}

variable "cwagent_config_mid_json_path" {
  description = "CW_CONFIG_CONTENT_MID に登録する JSON ファイル (モジュールからの相対パス)"
  type        = string
  default     = "../ecs/ssm/cwagent-config-mid.json"
}

variable "register_mid_parameter" {
  description = "CW_CONFIG_CONTENT_MID 用のパラメータを登録するか。false なら主設定 1 本だけ登録する"
  type        = bool
  default     = true
}

# --- 暗号化 (SecureString) -----------------------------------------------------

variable "create_kms_key" {
  description = "SecureString 用の KMS カスタマーマネージドキーを作成するか。false かつ kms_key_id 未指定なら AWS 管理キー (alias/aws/ssm) を使う"
  type        = bool
  default     = false
}

variable "kms_key_id" {
  description = "SecureString の暗号化に使う既存キー (key id / ARN / alias/xxx)。null かつ create_kms_key=false なら alias/aws/ssm"
  type        = string
  default     = null
}

variable "kms_key_deletion_window_in_days" {
  description = "create_kms_key=true のときのキー削除待機日数"
  type        = number
  default     = 30
}

# --- その他 -------------------------------------------------------------------

variable "parameter_tier" {
  description = "パラメータのティア。Standard は 4KB, Advanced は 8KB。Intelligent-Tiering は必要時のみ Advanced へ自動昇格"
  type        = string
  default     = "Intelligent-Tiering"

  validation {
    condition     = contains(["Standard", "Advanced", "Intelligent-Tiering"], var.parameter_tier)
    error_message = "parameter_tier は Standard / Advanced / Intelligent-Tiering のいずれかです。"
  }
}

variable "tags" {
  description = "全リソースへ付けるタグ"
  type        = map(string)
  default     = {}
}
