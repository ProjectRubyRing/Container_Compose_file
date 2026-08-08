# SSM Parameter Store (SecureString) に登録する CloudWatch Agent 設定の実体

このディレクトリの JSON は **「Parameter Store に SecureString として登録した JSON 文字列」そのもの**
であり、ローカル compose では `cwagent-ssm` サービスへ `/opt/cwagent-ssm/params` として
読み取り専用でマウントされる。

| ファイル | 対応する環境変数 | 対応するパラメータ名 (ローカル偽装) | 対応するパラメータ名 (ECS) |
| --- | --- | --- | --- |
| `cwagent-config.json` | `CW_CONFIG_CONTENT` | `/myapp/local/cwagent-config` | `/<APP_NAME>/<ENV>/cwagent-config` |
| `cwagent-config-mid.json` | `CW_CONFIG_CONTENT_MID` | `/myapp/local/cwagent-config-mid` | `/<APP_NAME>/<ENV>/cwagent-config-mid` |

- `cwagent-config.json` … **デフォルトロードされる主設定**。`agent` / `logs.endpoint_override` /
  `force_flush_interval` と、アプリのログ (`/mnt/logs/app-*.log`) の収集定義を持つ。
- `cwagent-config-mid.json` … **追加設定 (ミドルウェアログ)**。`logs.logs_collected.files.collect_list`
  だけを持ち、`agent` や `endpoint_override` は**持たない**。
  主設定とマージされて初めて成立するため、「マージが実際に効いているか」の判定材料になる
  (マージされていなければ `/local/myapp/ssm/mid/*` のログは送信されない)。

ECS 側に登録する実体は `ecs/ssm/cwagent-config.json` / `ecs/ssm/cwagent-config-mid.json` で、
Parameter Store への登録は `terraform/` (推奨) もしくは `ecs/ssm/register-parameters.sh` で行う。

詳細は [docs/CWAGENT-SSM-CONFIG.md](../../../docs/CWAGENT-SSM-CONFIG.md) を参照。
