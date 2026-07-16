# JBoss EAP 8.1 (UBI9/OpenJDK21) + ADOT Java Agent 自動計装 → X-Ray 構成一式

ECS/Fargate 本番構成と、AWS に接続せずローカル完結で等価検証できる compose 構成。

## ディレクトリ構成

```
compose.yaml                         # ローカル検証用 compose (Jaeger を X-Ray の代替 UI に)
DESIGN.md                            # 設計判断の根拠・デプロイ手順・トラブルシューティング
.env.example                         # compose 用環境変数の雛形 (→ .env にコピー)
verify-local.sh                      # ローカル動作確認スクリプト
compose/
  otel/adot-collector-local.yaml     # ADOT Collector ローカル設定 (debug + Jaeger 出力)
  mysql/init.sql                     # appdb: XA_RECOVER_ADMIN 付与ほか初期化
  mysql/init-infdb.sh                # infdb / infuser の作成 (2 スキーマ目)
  svf-mock/mappings/report.json      # SVF 帳票サーバの WireMock スタブ
  ecs-metadata-mock/mappings/        # ECS Task Metadata Endpoint v4 の WireMock スタブ
  cwagent/cwagent-config.json        # CloudWatch Agent ローカル設定 (endpoint_override → mock)
  cloudwatch-logs-mock/mappings/     # CloudWatch Logs API の WireMock スタブ (送信の偽装先)
docker/
  cli/mysql-xa-datasource.cli        # ビルド時 JBoss CLI (XA データソース / 2PC 設定)
  front/Dockerfile, entrypoint.sh    # フロントコンテナ (HTTP 8080)
  back/Dockerfile,  entrypoint.sh    # バックコンテナ (HTTP 8180 = port-offset 100)
  front/app/, back/app/              # ここに WAR を置く (アプリコード無改変)
ecs/
  taskdef.json                       # Fargate タスク定義 (front/back/ADOT/CW Agent 4 コンテナ)
  ssm/adot-collector-config.yaml     # Parameter Store 登録用 ADOT Collector 設定 (awsxray)
  ssm/cwagent-config.json            # Parameter Store 登録用 CloudWatch Agent 設定
  ssm/register-parameters.sh         # aws ssm put-parameter 登録スクリプト
  iam/task-role-policy.json          # タスクロール (X-Ray / CW メトリクス)
  iam/task-execution-role-policy.json# タスク実行ロール (ECR / logs / SSM / KMS)
```

## ローカル検証 (AWS 非接続)

```bash
cp .env.example .env          # EAP_BASE_IMAGE を設定 (DB パスワードはテスト用に compose.yaml へ直書き済み)
docker compose up -d --build
./verify-local.sh
# Jaeger UI: http://localhost:16686
```

## EFS / CloudWatch Logs 転送の偽装

- `efs-mock` が named volume (`efs-logs` / `efs-data`) を **UID 6301 / GID 6302, mode 2775 (setgid)** で
  初期化し、front/back へ `/mnt/logs` `/mnt/data` としてマウントする
  (EFS をアクセスポイント不使用・マウントポイントのみで利用する運用を模擬)。
- front/back は `group_add: 6302` で書き込み権限を得る。named volume のため
  **ホスト側のディレクトリ権限の変更は不要** (compose 環境内で完結)。
- `cwagent` (ECS taskdef と同じ CloudWatch Agent イメージ) が `/mnt/logs` の
  `app-front*.log` / `app-back*.log` を検知・tail し、`logs.endpoint_override` により
  実 AWS ではなく `cloudwatch-logs-mock` (WireMock, http://localhost:8480) へ PutLogEvents を送信する。
- 送信の確認 (件数):

```bash
curl -s -X POST http://localhost:8480/__admin/requests/count \
  -H "Content-Type: application/json" \
  -d '{"method":"POST","url":"/","headers":{"X-Amz-Target":{"equalTo":"Logs_20140328.PutLogEvents"}}}'
```

## 置き換えプレースホルダー

`<AWS_REGION>` `<ACCOUNT_ID>` `<ECS_CLUSTER_NAME>` `<ECS_SERVICE_NAME>` `<APP_NAME>` `<ENV>`
`<IMAGE_TAG>` `<EAP_BASE_IMAGE>` `<RDS_PROXY_ENDPOINT>` `<VALKEY_ENDPOINT>` `<REPORT_ALB_DNS_NAME>`
`<DB_NAME>` `<DB_USER>` `<KMS_KEY_ID>`

詳細な設計説明・トラブルシューティングは [DESIGN.md](DESIGN.md) を参照。
