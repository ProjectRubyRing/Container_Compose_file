# CloudWatch Agent 設定を SSM Parameter Store (SecureString) から注入する

ECS タスク定義の `secrets` で **`CW_CONFIG_CONTENT`** に注入した JSON を CloudWatch Agent が
デフォルトロードする仕組みと、**`CW_CONFIG_CONTENT_MID` のような追加の環境変数**を足したときの
挙動を、ローカル compose で偽装再現するための構成。Parameter Store への登録は Terraform で行う。

---

## 1. 何を偽装し、何を偽装していないか

実 ECS では 2 段構えになっている。

```
(1) SSM → 環境変数        ECS エージェントがタスク起動時に Parameter Store から
                          値を取得し、SecureString なら KMS で復号して、
                          復号後の JSON 文字列を環境変数としてコンテナへ渡す。
                          コンテナから見えるのは「JSON 文字列が入った環境変数」だけ。

(2) 環境変数 → 実効設定    CloudWatch Agent はコンテナ実行時 (RUN_IN_CONTAINER=True)、
                          設定ディレクトリ /etc/cwagentconfig を --input-dir として読み、
                          中の JSON ファイルをすべてマージして起動する。
                          CW_CONFIG_CONTENT はこの入口へ流し込まれる「既定の設定」。
```

ローカル compose の `cwagent-ssm` サービスが偽装するのは **(1) と、(2) への流し込みまで**。

| 層 | ローカルで担当するもの | 偽装か実物か |
| --- | --- | --- |
| Parameter Store の値 | `compose/cwagent/ssm/*.json` | 偽装 (ファイルが「パラメータの値」) |
| SSM 取得 + KMS 復号 | `compose/cwagent/ssm-config-entrypoint.sh` | 偽装 |
| 環境変数 → `/etc/cwagentconfig` への materialize | 同上 | 偽装 (ECS でも taskdef の `entryPoint` が同じことをする) |
| **設定のマージ・解釈・収集・送信** | **CloudWatch Agent 本体** | **実物** |
| CloudWatch Logs API | `cloudwatch-logs-mock` (WireMock) | 偽装 |

マージと設定解釈を実エージェントにそのまま行わせているため、
**ローカルで成立した JSON は、同じものを Parameter Store に登録すれば ECS でも同じ実効設定になる。**

```
compose/cwagent/ssm/cwagent-config.json      (= Parameter Store に入れる値そのもの)
compose/cwagent/ssm/cwagent-config-mid.json
        │  ssm-config-entrypoint.sh  (SSM 取得 + 復号の偽装)
        ▼
環境変数 CW_CONFIG_CONTENT / CW_CONFIG_CONTENT_MID
        │  ssm-config-entrypoint.sh  (デフォルトロードの偽装)
        ▼
/etc/cwagentconfig/00-cwagent-config.json
/etc/cwagentconfig/10-cwagent-config-mid.json
        │  ★ここから先は CloudWatch Agent 本体 (マージ / translator)
        ▼
/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json   (= 実効設定)
```

---

## 2. `CW_CONFIG_CONTENT_MID` を足すときの重要な前提

**CloudWatch Agent が自動で読む環境変数は `CW_CONFIG_CONTENT` の 1 本だけ**で、
`CW_CONFIG_CONTENT_MID` のような追加変数は素のままでは読まれない。

したがって「設定を複数のパラメータに分けて注入する」構成にする場合は、
**ローカルだけでなく ECS 側でも、環境変数を `/etc/cwagentconfig/` へ書き出す処理が必要**になる。
`ecs/taskdef.json` の `cwagent` コンテナには、ローカルのラッパーと等価な処理を
`entryPoint` のインライン sh として入れてある。

```jsonc
"entryPoint": [
  "/bin/sh", "-c",
  "if [ -n \"$CW_CONFIG_CONTENT\" ]; then printf '%s' \"$CW_CONFIG_CONTENT\" > /etc/cwagentconfig/00-cwagent-config.json; fi; if [ -n \"$CW_CONFIG_CONTENT_MID\" ]; then printf '%s' \"$CW_CONFIG_CONTENT_MID\" > /etc/cwagentconfig/10-cwagent-config-mid.json; fi; unset CW_CONFIG_CONTENT CW_CONFIG_CONTENT_MID; exec /opt/aws/amazon-cloudwatch-agent/bin/start-amazon-cloudwatch-agent"
]
```

設計上のポイント:

- **数値プレフィクス (`00-` / `10-`) がマージ順**になる。主設定を先に、追加設定を後に置く。
- **`unset` してからエージェントを起動する。** エージェント側にも `CW_CONFIG_CONTENT` を
  読む経路があるため、残したままだと同じ設定が二重に読まれ `collect_list` が重複しうる。
- **`/etc/cwagentconfig` はタスクレベルの volume でマウントする**
  (`"volumes": [{ "name": "cwagentconfig" }]` + `mountPoints`)。
  CloudWatch Agent のイメージには `mkdir(1)` が無い場合があるため、
  ディレクトリの存在をコンテナ外の仕組みで保証しておく。
  ローカル compose では同じ役割を `tmpfs: [/etc/cwagentconfig]` が果たす。
- `CW_CONFIG_CONTENT_MID` を使わない構成に戻すのは、taskdef から `secrets` の 1 件を
  削るだけでよい (`entryPoint` は未設定の変数を無視する)。

「MID」は単なる接尾辞で、`compose/cwagent/ssm/cwagent-config-mid.json` の中身としては
**ミドルウェア (JBoss EAP) のログ収集定義**を割り当ててある。3 本目以降を足す場合も
`CWA_SSM_PARAMS` に追記すれば同じ仕組みで動く。

---

## 3. ローカルでの再現確認

既存の `cwagent` サービス (ファイルマウント方式) は**一切変更していない**。
SSM 注入方式は `profiles: ssm-config` でゲートした **別サービス `cwagent-ssm`** として追加してあるため、
通常の `docker compose up` の挙動は従来どおり。

```bash
docker compose up -d --build                        # 従来どおりの構成を起動
docker compose --profile ssm-config up -d cwagent-ssm
./verify-cwagent-ssm.sh
```

`verify-cwagent-ssm.sh` が確認するもの:

| # | 確認内容 | 判定方法 |
| --- | --- | --- |
| 2 | 2 つのパラメータが解決されたか | ラッパーの `[cwagent-ssm]` ログ |
| 3 | `/etc/cwagentconfig` へ materialize されたか | `docker cp` で取り出して中身を表示 |
| 4 | **実エージェントが両方をマージしたか** | 実効設定に両系統の `log_group_name` が載っているか |
| 6 | マージ結果どおりに送信されたか | `cloudwatch-logs-mock` の request journal をロググループ名で集計 |

**4 がこの検証の本丸。** materialize は「ラッパーが置いた」だけの証跡だが、
translator が出力する実効設定に両方のロググループが載っていることは、
実エージェントが 2 つのパラメータをマージした証跡になる。

追加設定 (`cwagent-config-mid.json`) には `agent` も `logs.endpoint_override` も**書いていない**。
主設定とマージされて初めて送信先が決まるため、`/local/myapp/ssm/mid/*` のログが
`cloudwatch-logs-mock` に届いていれば「上書きではなく合成」が起きたことになる。

ロググループ名は既存の `cwagent` (`/local/myapp/efs/*`) と変えてある (`/local/myapp/ssm/*`) ので、
両サービスを同時に起動しても request journal でどちらの経路か区別できる。

### 環境変数を直接与えて ECS と同じ状態で検証する

既定ではパラメータの値を `compose/cwagent/ssm/*.json` から読む (JSON を YAML へ直書きせずに済む)。
ECS の `secrets` と完全に同じ「環境変数に JSON 文字列が入った状態」から検証したい場合は、
`cwagent-ssm` の `environment:` に直接書けばそちらが優先される。

```yaml
    environment:
      CW_CONFIG_CONTENT: '{"agent":{"region":"ap-northeast-1"},"logs":{...}}'
      CWA_SSM_UNSET_AFTER: "0"   # エージェントへ環境変数を残したまま渡す
```

### ラッパーの調整用環境変数

| 変数 | 既定 | 説明 |
| --- | --- | --- |
| `CWA_SSM_PARAMS` | `CW_CONFIG_CONTENT=/myapp/local/cwagent-config CW_CONFIG_CONTENT_MID=/myapp/local/cwagent-config-mid` | 「環境変数名=パラメータ名」の空白区切り。**並び順がマージ順** |
| `CWA_SSM_VALUE_DIR` | `/opt/cwagent-ssm/params` | パラメータの値 (JSON) の置き場所 |
| `CWA_SSM_CONFIG_DIR` | `/etc/cwagentconfig` | materialize 先 (= エージェントの `--input-dir`) |
| `CWA_SSM_UNSET_AFTER` | `1` | materialize 後に環境変数を unset する (二重ロード防止) |
| `CWA_SSM_CLEAN_DIR` | `1` | 起動時に materialize 先の `*.json` を消す (冪等化) |
| `CWA_SSM_STRICT` | `0` | `1` なら FAIL 時に起動を止める |

---

## 4. Parameter Store への登録 (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # app_name / env を設定
terraform init && terraform apply

terraform output parameter_summary        # 登録結果の一覧
terraform output -raw verify_commands     # AWS CLI での確認コマンド
terraform output -raw ecs_taskdef_secrets # taskdef へ貼る secrets ブロック
```

登録されるもの:

| パラメータ | 型 | 注入される環境変数 |
| --- | --- | --- |
| `/<app_name>/<env>/cwagent-config` | `SecureString` | `CW_CONFIG_CONTENT` |
| `/<app_name>/<env>/cwagent-config-mid` | `SecureString` | `CW_CONFIG_CONTENT_MID` |

- 値は `ecs/ssm/cwagent-config.json` / `ecs/ssm/cwagent-config-mid.json` を読み、
  `<APP_NAME>` `<ENV>` `<AWS_REGION>` `<ACCOUNT_ID>` を実値へ置換して登録する。
- `jsondecode` → `jsonencode` で **JSON の妥当性を plan 時に検証しつつ 1 行へ最小化**する。
  壊れた JSON は `apply` する前に落ちる。
- Standard tier (4KB) の上限超過も `plan` 時の precondition で検出する。
- SecureString の値そのものは output しない。同一性は `value_sha256` で確認する。

変数・注意点は [../terraform/README.md](../terraform/README.md) を参照。

`ecs/ssm/register-parameters.sh` でも同じ 2 本を登録できる (Terraform を使わない場合):

```bash
CWAGENT_SECURESTRING=1 KMS_KEY_ALIAS=alias/myapp-prod-ssm \
  AWS_REGION=ap-northeast-1 APP_NAME=myapp ENV=prod ./register-parameters.sh
```

**Terraform とスクリプトのどちらか一方に寄せること** (既定 `CWAGENT_SECURESTRING=0` では
従来どおり `cwagent-config` を `String` 1 本で登録する)。

---

## 5. トラブルシューティング

| 症状 | 見るところ | 原因の典型 |
| --- | --- | --- |
| `[cwagent-ssm]` ログが出ない | `compose.yaml` の `cwagent-ssm.entrypoint` | スクリプトのマウント漏れ |
| `パラメータの値が見つからない` | `CWA_SSM_PARAMS` とファイル名 | パラメータ名の最後の要素と `<名前>.json` が不一致 |
| `materialize 先がディレクトリとして存在しない` | `tmpfs` / ECS の `mountPoints` | `/etc/cwagentconfig` が用意されていない |
| 実効設定を取り出せない | `docker compose logs cwagent-ssm \| grep -E 'Under path :\|E!'` | translator が JSON を解釈できていない |
| 主設定だけ反映され MID が無い | 上記 translator ログ + 3 の materialize 一覧 | 追加設定側の JSON 不正 (その 1 ファイルだけ無視される) |
| どのロググループも送信 0 件 | `verify-cwagent-ssm.sh` の 4 → 7 | 設定は読めているがファイル検知に失敗 (`file_path` と実際の出力先のズレ) |
| ECS で MID だけ効かない | taskdef の `entryPoint` | エージェントは `CW_CONFIG_CONTENT` しか自動ロードしない (2 章) |
| ECS で `unable to pull secrets` | 実行ロールの `ssm:GetParameters` / `kms:Decrypt` | `cwagent-config-mid` の ARN が IAM ポリシーに無い |
| パラメータを更新したのに変わらない | ECS のデプロイ | `secrets` はタスク起動時にしか解決されない (`--force-new-deployment`) |

CloudWatch Agent のイメージには `ls` / `cat` が無いため、`docker compose exec cwagent-ssm ls ...` は
「設定が無い」ではなく「`ls` が無い」で失敗する。判定には使わないこと
(詳細は [../README.md](../README.md) の cwagent 自己診断の節)。コンテナ内バイナリに依存しない確認:

```bash
# materialize 結果を丸ごと取り出す
docker cp cwagent-ssm:/etc/cwagentconfig/. ./cwagentconfig-out

# エージェントが実際に使っている実効設定
docker cp cwagent-ssm:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json ./translated.json
```
