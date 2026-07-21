# JBoss EAP 8.1 (UBI9/OpenJDK21) + ADOT Java Agent 自動計装 → X-Ray 構成一式

ECS/Fargate 本番構成と、AWS に接続せずローカル完結で等価検証できる compose 構成。

## ディレクトリ構成

```
compose.yaml                         # ローカル検証用 compose (Jaeger を X-Ray の代替 UI に)
DESIGN.md                            # 設計判断の根拠・デプロイ手順・トラブルシューティング
docs/ASYNC-SQS-LAMBDA-ALB.md         # 非同期チェーン (SQS→Lambda→ALB→app-back) 詳細ガイド
docs/MYSQL-8.4-AURORA-UPGRADE.md     # Aurora 8.4 / MySQL 8.4.7 化・Connector/J 9.7.0 の詳細解説
.env.example                         # compose 用環境変数の雛形 (→ .env にコピー)
verify-local.sh                      # ローカル動作確認スクリプト
verify-async.sh                      # 非同期チェーンの動作確認スクリプト
alb-maintenance.sh                   # ALB 全面メンテナンスモードの ON/OFF 切り替え
compose/
  otel/adot-collector-local.yaml     # ADOT Collector ローカル設定 (debug + Jaeger 出力)
  mysql/init.sql                     # appdb: XA_RECOVER_ADMIN 付与ほか初期化
  mysql/init-infdb.sh                # infdb / infuser の作成 (2 スキーマ目)
  svf-mock/mappings/report.json      # SVF 帳票サーバの WireMock スタブ
  ecs-metadata-mock/mappings/        # ECS Task Metadata Endpoint v4 の WireMock スタブ
  cwagent/cwagent-config.json        # CloudWatch Agent ローカル設定 (endpoint_override → mock)
  cloudwatch-logs-mock/mappings/     # CloudWatch Logs API の WireMock スタブ (送信の偽装先)
  sqs/elasticmq.conf                 # SQS のローカル代替 (ElasticMQ) キュー/DLQ 設定
  lambda/app/handler.py              # Lambda 関数 (SQS→ALB→app-back を POST 呼び出し)
  lambda-esm/poller.py, Dockerfile   # SQS イベントソースマッピングの代替 (poller)
  alb/nginx.conf                     # ALB のローカル代替 (nginx L7 ルーティング)
  alb/rules/                         # ALB リスナールール (★差し替え可能★, variants/ に切り替えソース)
  maintenance-lambda/app/maintenance.py  # メンテナンス画面 Lambda (★差し替え可能★, 画面HTML+503)
  alb-lambda-adapter/adapter.py      # ALB の Lambda ターゲット統合 (HTTP↔Lambda 変換) の代替
docker/
  cli/mysql-xa-datasource.cli        # ビルド時 JBoss CLI (JDBC ドライバ登録 / XA データソース / 2PC 設定)
  modules/com/mysql/main/module.xml  # Connector/J 9.7.0 の JBoss 静的モジュール定義 (module.xml)
  front/Dockerfile, entrypoint.sh    # フロントコンテナ (HTTP 8080)
  back/Dockerfile,  entrypoint.sh    # バックコンテナ (HTTP 8180 = port-offset 100)
  back/servlet/                      # 非同期チェーン受け口の Java サーブレット WAR (Maven)
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

## 非同期処理チェーン (SQS → Lambda → ALB → app-back)

app-front / app-back から非同期にキューへ積み、SQS → Lambda → ALB を経由して
app-back の Java サーブレット (`/async/receive`) が POST を受け取るまでを、
AWS 非接続でローカル再現する。

```bash
docker compose up -d --build
./verify-async.sh
```

- `sqs` (ElasticMQ) が `app-async-queue` / DLQ を提供
- `lambda-esm` (poller) がキューをポーリングして `lambda` (RIE + `handler.py`) を起動
- `lambda` が `alb` (nginx) 経由で app-back の `AsyncReceiverServlet` を POST 呼び出し

### メンテナンス画面 Lambda / ALB リスナールール切り替え

ALB のリスナールールからメンテナンス画面 Lambda を呼び出し、メンテナンス画面 (HTML) と
ステータスコード (既定 503) を返す。Python コードもルール切り替えも差し替え可能。

```bash
curl -i http://localhost:9080/maintenance   # 常時: メンテナンス画面プレビュー
./alb-maintenance.sh on                      # 全面メンテナンス (全経路→503+画面)
./alb-maintenance.sh off                     # 通常 (app-back) へ戻す
```

- `maintenance-lambda` (RIE + `maintenance.py`) が画面 HTML とステータスコードを返す (`maintenance.py` は差し替え可)
- `alb-lambda-adapter` が ALB の Lambda ターゲット統合 (HTTP↔Lambda 変換) を代替
- リスナールールは `compose/alb/rules/*.conf` に分離 (`variants/` に通常/メンテの切り替えソース)

ポート: SQS API `:9324` / ElasticMQ UI `:9325` / 非同期 Lambda `:9000` /
メンテ Lambda `:9001` / ALB `:9080` / adapter `:9081`

**実装・設定方法の詳細は [docs/ASYNC-SQS-LAMBDA-ALB.md](docs/ASYNC-SQS-LAMBDA-ALB.md) を参照。**

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
