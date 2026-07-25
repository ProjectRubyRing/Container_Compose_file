# JBoss EAP 8.1 (UBI9/OpenJDK21) + ADOT Java Agent 自動計装 → X-Ray 構成一式

ECS/Fargate 本番構成と、AWS に接続せずローカル完結で等価検証できる compose 構成。

## ディレクトリ構成

```
compose.yaml                         # ローカル検証用 compose (Jaeger を X-Ray の代替 UI に)
DESIGN.md                            # 設計判断の根拠・デプロイ手順・トラブルシューティング
docs/ASYNC-SQS-LAMBDA-ALB.md         # 非同期チェーン (SQS→Lambda→ALB→app-back) 詳細ガイド
docs/MYSQL-8.4-AURORA-UPGRADE.md     # Aurora 8.4 / MySQL 8.4.7 化・Connector/J 9.7.0 の詳細解説
docs/TLS-SELF-SIGNED-ALB.md          # 自己署名証明書 HTTPS / JVM トラストストア / ALB 証明書の詳細ガイド
.env.example                         # compose 用環境変数の雛形 (→ .env にコピー)
verify-local.sh                      # ローカル動作確認スクリプト
verify-async.sh                      # 非同期チェーンの動作確認スクリプト
verify-tls.sh                        # 自己署名証明書 HTTPS 経路の動作確認スクリプト
alb-maintenance.sh                   # ALB 全面メンテナンスモードの ON/OFF 切り替え
alb-tls-cert.sh                      # ALB HTTPS リスナーの証明書切り替え (自己署名 / 中間CA発行)
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
  alb/nginx.conf                     # ALB のローカル代替 (nginx L7 ルーティング / HTTP:80 + HTTPS:443)
  alb/rules/                         # ALB リスナールール (★差し替え可能★, variants/ に切り替えソース)
  alb/rules-tls/                     # HTTPS リスナーのルール (★差し替え可能★)
  alb/tls/                           # HTTPS リスナーに適用する証明書 (★差し替え可能★, variants/ あり)
  pki/gen-certs.sh, Dockerfile       # 自己署名 PKI 発行 (ルートCA→中間CA→サーバ証明書)
  secure-api/mappings/               # HTTPS 専用 REST API (WireMock) のスタブ
  tls-verifier/verify-tls.sh, Dockerfile # TLS 経路の検証コンテナ (compose ネットワーク内から実行)
  maintenance-lambda/app/maintenance.py  # メンテナンス画面 Lambda (★差し替え可能★, 画面HTML+503)
  alb-lambda-adapter/adapter.py      # ALB の Lambda ターゲット統合 (HTTP↔Lambda 変換) の代替
docker/
  cli/mysql-xa-datasource.cli        # ビルド時 JBoss CLI (JDBC ドライバ登録 / XA データソース / 2PC 設定)
  modules/com/mysql/main/module.xml  # Connector/J 9.7.0 の JBoss 静的モジュール定義 (module.xml)
  front/Dockerfile, entrypoint.sh    # フロントコンテナ (HTTP 8080)
  back/Dockerfile,  entrypoint.sh    # バックコンテナ (HTTP 8180 = port-offset 100)
  back/servlet/                      # 非同期チェーン受け口の Java サーブレット WAR (Maven)
  probe/                             # TLS 検証用サーブレット WAR (front/back 両方に配備)
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

## 自己署名証明書による HTTPS 検証 (secure-api / JVM トラストストア / ALB)

自己署名 CA で発行した証明書でのみ HTTPS を受け付ける REST API サーバを追加し、
**front/back の JVM トラストストアへ CA (または自己署名証明書そのもの) を取り込むことで、
アプリコードを無改変のまま REST API を呼び出せる**ことを検証する。ALB 経由も同様に検証できる。

```bash
docker compose up -d --build
./verify-tls.sh                 # 一括検証 (コンテナ内 + ホストから)
./verify-tls.sh quick           # JVM 経路のみ (短時間)
```

- `pki-init` が **ルート CA (自己署名) → 中間 CA → 各サーバ証明書** を発行し、named volume で全コンテナへ配る
- `secure-api` (WireMock, `--disable-http`) が **HTTPS でのみ** REST API を提供 (`:8543`)
- `app-front` / `app-back` の entrypoint が `keytool` で **JDK 同梱 cacerts のコピーへ CA を追加**し、
  `-Djavax.net.ssl.trustStore` で JVM に指定する (パブリック CA の信頼は残したまま追加)
- `tls-probe.war` を front/back 両方に配備し、**その JVM 自身から** HTTPS 呼び出しを実行して確認できる
- `alb` に **HTTPS リスナー (`:9443`)** を追加。`/secure/*` は secure-api へ HTTPS 再暗号化で転送

```bash
# front の JVM から secure-api を直接 / ALB 経由で呼ぶ
curl -s "http://localhost:8080/tls-probe/check?target=direct" | jq .
curl -s "http://localhost:8180/tls-probe/check?target=alb"    | jq .
curl -s  http://localhost:8080/tls-probe/truststore           | jq .   # 取り込み済み証明書

# ALB の証明書を切り替える (自己署名 ⇄ 中間 CA 発行)。reload のみで即時反映
./alb-tls-cert.sh selfsigned | ca-issued | status
```

「自己証明書そのものをインポートする」「中間 CA 証明書をインポートする」の
**両パターンを同時に検証できる**よう、ALB 用に自己署名リーフと中間 CA 発行の 2 種類を発行している。

ポート: secure-api `:8543` (HTTPS) / ALB HTTPS リスナー `:9443`

**実装・設定方法の詳細は [docs/TLS-SELF-SIGNED-ALB.md](docs/TLS-SELF-SIGNED-ALB.md) を参照。**

## EFS / CloudWatch Logs 転送の偽装

- `efs-mock` が named volume (`efs-logs` / `efs-data`) を **UID 6301 / GID 6302, mode 2775 (setgid)** で
  初期化し、front/back へ `/mnt/logs` `/mnt/data` としてマウントする
  (EFS をアクセスポイント不使用・マウントポイントのみで利用する運用を模擬)。
- front/back は `group_add: 6302` で書き込み権限を得る。named volume のため
  **ホスト側のディレクトリ権限の変更は不要** (compose 環境内で完結)。
- 各 entrypoint は起動時に `umask 0002` を設定し、役割別サブディレクトリ
  (`/mnt/logs/front/logs` など) を **setgid + group-write (mode 2775)** で冪等に作成する。
  これにより、setgid 親配下でも既定 umask (0022) で group write ビットが落ちて
  GID 6302 を共有する別プロセスが配下へディレクトリを作れなくなる問題を回避する
  (umask は `exec` 先の JBoss にも継承され、実行時に作るディレクトリ/ファイルも
  group-writable になる)。
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
