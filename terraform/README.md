# Terraform: CloudWatch Agent 設定を Parameter Store (SecureString) へ登録する

ECS タスク定義の `secrets` から `CW_CONFIG_CONTENT` / `CW_CONFIG_CONTENT_MID` として
注入する JSON を、SSM Parameter Store へ **SecureString** で登録し、
登録結果を `terraform output` で確認できるようにするルートモジュール。

| パラメータ (既定) | 注入される環境変数 | 役割 | 値の既定の取得元 |
| --- | --- | --- | --- |
| `/<app_name>/<env>/cwagent-config` | `CW_CONFIG_CONTENT` | デフォルトロードされる主設定 | `../ecs/ssm/cwagent-config.json` |
| `/<app_name>/<env>/cwagent-config-mid` | `CW_CONFIG_CONTENT_MID` | 追加設定 (マージされる) | `../ecs/ssm/cwagent-config-mid.json` |

登録前に `<APP_NAME>` `<ENV>` `<AWS_REGION>` `<ACCOUNT_ID>` を実値へ置換し、
`jsondecode` → `jsonencode` で **JSON として妥当かを plan 時に検証しつつ 1 行へ最小化**する
(パラメータのサイズ上限に効き、ECS が環境変数へ入れるのと同じ姿になる)。

## 使い方

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # app_name / env を設定
terraform init
terraform plan
terraform apply
```

### 登録結果の確認

```bash
# 一覧 (環境変数名 / パラメータ名 / ARN / 型 / ティア / バージョン / サイズ / sha256)
terraform output parameter_summary

# AWS CLI での確認コマンドを表示 (メタデータ / 復号した値 / sha256 の突き合わせ)
terraform output -raw verify_commands

# タスク定義へ貼る secrets ブロック
terraform output -raw ecs_taskdef_secrets

# タスク実行ロールの ssm:GetParameters へ足す Resource
terraform output -raw iam_policy_resources

# ECS への反映手順
terraform output -raw next_steps
```

`parameter_summary` の出力例:

```
{
  "CW_CONFIG_CONTENT" = {
    "arn"          = "arn:aws:ssm:ap-northeast-1:123456789012:parameter/myapp/prod/cwagent-config"
    "env_var"      = "CW_CONFIG_CONTENT"
    "kms_key_id"   = "alias/aws/ssm (AWS managed)"
    "name"         = "/myapp/prod/cwagent-config"
    "role"         = "デフォルトロードされる主設定"
    "source"       = "../ecs/ssm/cwagent-config.json"
    "tier"         = "Intelligent-Tiering"
    "type"         = "SecureString"
    "value_bytes"  = 261
    "value_sha256" = "3573308..."
    "version"      = 1
  }
  "CW_CONFIG_CONTENT_MID" = { ... }
}
```

**SecureString の値そのものは出力しない。** 同一性は `value_sha256` で確認し、
中身を見たいときは `verify_commands` の `get-parameter --with-decryption` を使う。

## 主な変数

| 変数 | 既定 | 説明 |
| --- | --- | --- |
| `app_name` / `env` | (必須) | パラメータ名 `/<app_name>/<env>/...` に使う。taskdef の `<APP_NAME>` `<ENV>` と一致させる |
| `aws_region` | `ap-northeast-1` | 登録先リージョン |
| `cwagent_config_json_path` | `../ecs/ssm/cwagent-config.json` | 主設定の JSON ファイル (モジュール相対) |
| `cwagent_config_mid_json_path` | `../ecs/ssm/cwagent-config-mid.json` | 追加設定の JSON ファイル |
| `cwagent_config_json` / `cwagent_config_mid_json` | `null` | JSON を直接渡す (指定するとファイルより優先) |
| `register_mid_parameter` | `true` | `false` なら主設定 1 本だけ登録する |
| `create_kms_key` | `false` | `true` で CMK と `alias/<app>-<env>-ssm` を作成 |
| `kms_key_id` | `null` | 既存キーを使う場合に指定。未指定かつ `create_kms_key=false` なら `alias/aws/ssm` |
| `parameter_tier` | `Intelligent-Tiering` | `Standard`(4KB) / `Advanced`(8KB) / `Intelligent-Tiering` |

ローカル compose で検証済みの JSON をそのまま登録したい場合は、パスを
`../compose/cwagent/ssm/*.json` に向ける (`terraform.tfvars.example` にコメントあり)。

## 注意

- **`register-parameters.sh` との二重管理を避ける。**
  `ecs/ssm/register-parameters.sh` は既定では `cwagent-config` を `String` で登録する。
  Terraform で管理する場合は同スクリプトの `CWAGENT_SECURESTRING` を **1 にしない**
  (= このモジュールだけで登録する)。既に `String` で登録済みのパラメータに対して
  `apply` すると、型が `SecureString` へ更新される。
- **反映にはタスクの再起動が必要。** `secrets` はタスク起動時にしか解決されないため、
  パラメータを更新しても既存タスクには反映されない (`--force-new-deployment`)。
- **CMK を使う場合は IAM も合わせる。** `ecs/iam/task-execution-role-policy.json` の
  `KmsDecryptForSecureString` の `<KMS_KEY_ID>` を、作成/指定したキーに置き換える。
  AWS 管理キー (`alias/aws/ssm`) を使う場合、実行ロールに追加の `kms:Decrypt` は不要。
- `.terraform.lock.hcl` はコミット対象。`terraform.tfvars` / `*.tfstate` は `.gitignore` 済み。

仕組みの全体像 (ローカル compose での偽装再現を含む) は
[../docs/CWAGENT-SSM-CONFIG.md](../docs/CWAGENT-SSM-CONFIG.md) を参照。
