# alb-healthcheck — ALB ターゲットグループのヘルスチェックの偽装

ECS/Fargate の本番構成では、ALB (Application Load Balancer) がターゲットグループの
ヘルスチェック設定に従って**タスクの外から**定期的に HTTP 要求を投げ、その
**ステータスコード**と**連続成功 / 連続失敗の回数**からターゲットの状態
(`initial` / `healthy` / `unhealthy`) を導出する。`unhealthy` になると ALB は
ルーティングを止め、ECS はタスクを置き換える。

compose の `healthcheck:` (= ECS タスク定義の `healthCheck`) は**コンテナの中で**
`curl` を実行するもので、ALB の判定とは別物。この偽装サービスは後者、つまり
「ALB から見たヘルスチェック」だけをローカルへ持ち込む。

| ファイル | 役割 |
|---|---|
| `healthcheck.py` | 偽装本体。定期チェック + 状態機械 + 状態参照 API + CLI (標準ライブラリのみ) |
| `targets.json` | ターゲットグループ定義 (★差し替え可能★。ALB のヘルスチェック設定と同じ項目) |

## 実 ALB と同じにしている点

- 要求は `GET <path>`、ヘッダは `Host: <target>:<port>` /
  `User-Agent: ELB-HealthChecker/2.0` / `Connection: close`
- `matcher` (HttpCode) に含まれるステータスコードだけを成功とする
- `timeout_seconds` を超えた応答は失敗 (`Target.Timeout`)
- `healthy_threshold_count` 回**連続成功**で `healthy` へ、
  `unhealthy_threshold_count` 回**連続失敗**で `unhealthy` へ遷移する
  (途中の 1 回の失敗では状態を変えない)
- 登録直後は `initial` (`Elb.RegistrationInProgress` → `Elb.InitialHealthChecking`)
  で、閾値に達するまで `healthy` にならない
- 失敗理由は ALB と同じ理由コードで表す
  (`Target.ResponseCodeMismatch` / `Target.Timeout` / `Target.FailedHealthChecks`)
- ターゲットグループのプロトコルが HTTPS の場合、ALB はターゲット証明書を検証しない

## 実 ALB と違う点 (ローカル都合)

- ターゲットは IP ではなく compose サービス名 (DNS 名) で指定する
- 1 ターゲットグループにターゲットは 1 つ (ECS の 1 タスク構成に合わせる)
- `draining` / `unused` / `unavailable` の状態は扱わない

## 設定 (targets.json)

| キー | 対応する ALB の設定 | 既定 |
|---|---|---|
| `name` | ターゲットグループ名 | (必須) |
| `compose_service` | ターゲットの compose サービス名 | (必須) |
| `ecs_container` | 参考表示用。ECS タスク定義側のコンテナ名 | `""` |
| `protocol` | `HealthCheckProtocol` | `HTTP` |
| `host` / `port` | 登録ターゲット (IP:ポート) | (必須) |
| `path` | `HealthCheckPath` | `/` |
| `matcher` | `Matcher.HttpCode` (`200` / `200,301` / `200-299`) | `200` |
| `interval_seconds` | `HealthCheckIntervalSeconds` | `30` |
| `timeout_seconds` | `HealthCheckTimeoutSeconds` | `5` |
| `healthy_threshold_count` | `HealthyThresholdCount` (2〜10) | `5` |
| `unhealthy_threshold_count` | `UnhealthyThresholdCount` (2〜10) | `2` |

`interval_seconds` / `matcher` / `path` を書き換えて
`docker compose restart alb-healthcheck` すれば、ALB のヘルスチェック設定を
変えたときの挙動をそのまま再現できる。

## 使い方

```bash
# 全ターゲットグループの状態 (JSON)
curl -s http://localhost:8580/targets | python -m json.tool

# 1 つ分 (ターゲットグループ名 / compose サービス名のどちらでも指定できる)
curl -s http://localhost:8580/targets/frontend

# その場で 1 回チェックする (状態機械の連続回数には反映しない)
curl -s http://localhost:8580/targets/backend/check

# 偽装サービスのコンテナ内から、人が読む形式のレポートを出す
docker compose exec alb-healthcheck \
  python3 /opt/alb-healthcheck/healthcheck.py report frontend
docker compose exec alb-healthcheck \
  python3 /opt/alb-healthcheck/healthcheck.py report --all

# ALB がどう判定しているかを 1 行ログで追う (ALB のアクセスログ相当)
docker compose logs -f alb-healthcheck
```

`report` の終了コードは `0` = OK (healthy かつその場のチェックも成功) /
`1` = NG / `2` = 実行不能 / `3` = 判定保留 (`initial`)。

## build_and_verify.sh からの確認

姉妹リポジトリ `Container_Compose_Build_Push_v2_from_Codex/build_and_verify.sh` を
`--keep-container-mode logs` で起動すると、`frontend` / `backend` /
`alb-healthcheck` を選んだときのサービス操作メニューに
**ALB ヘルスチェック確認 (ステータスコード / 成功失敗判定)** が出る。
詳細は [../../docs/ALB-HEALTHCHECK.md](../../docs/ALB-HEALTHCHECK.md) を参照。

## 失敗したときの読み方

| 症状 | 理由コード | 見るところ |
|---|---|---|
| `status=404` で `unhealthy` | `Target.ResponseCodeMismatch` | アプリのルート (`path`) が 200 を返すか。ALB 側の `matcher` を `200-399` にするかの判断 |
| `status=-` / `exit=28` | `Target.Timeout` | EAP の起動途中 (`start_period` 相当) か、応答が `timeout_seconds` より遅い |
| `status=-` / `exit=7` | `Target.FailedHealthChecks` | ターゲットのポートが listen していない |
| `status=-` / `exit=6` | `Target.FailedHealthChecks` | `host` の compose サービスが存在しない / 未起動 (名前解決不可) |
