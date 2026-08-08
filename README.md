# JBoss EAP 8.1 (UBI9/OpenJDK21) + ADOT Java Agent 自動計装 → X-Ray 構成一式

ECS/Fargate 本番構成と、AWS に接続せずローカル完結で等価検証できる compose 構成。

## ディレクトリ構成

```
compose.yaml                         # ローカル検証用 compose (Jaeger を X-Ray の代替 UI に)
DESIGN.md                            # 設計判断の根拠・デプロイ手順・トラブルシューティング
docs/ASYNC-SQS-LAMBDA-ALB.md         # 非同期チェーン (SQS→Lambda→ALB→app-back) 詳細ガイド
docs/CWAGENT-SSM-CONFIG.md           # CW_CONFIG_CONTENT / CW_CONFIG_CONTENT_MID による設定注入の詳細ガイド
docs/MYSQL-8.4-AURORA-UPGRADE.md     # Aurora 8.4 / MySQL 8.4.7 化・Connector/J 9.7.0 の詳細解説
docs/RDS-PROXY-TLS.md                # DB の TLS を RDS Proxy 相当にそろえる設定 / MY-010068 の読み方
docs/TLS-SELF-SIGNED-ALB.md          # 自己署名証明書 HTTPS / JVM トラストストア / ALB 証明書の詳細ガイド
.env.example                         # compose 用環境変数の雛形 (→ .env にコピー)
verify-local.sh                      # ローカル動作確認スクリプト
verify-async.sh                      # 非同期チェーンの動作確認スクリプト
verify-tls.sh                        # 自己署名証明書 HTTPS 経路の動作確認スクリプト
verify-cwagent-ssm.sh                # cwagent の SSM (SecureString) 設定注入の動作確認スクリプト
alb-maintenance.sh                   # ALB 全面メンテナンスモードの ON/OFF 切り替え
alb-tls-cert.sh                      # ALB HTTPS リスナーの証明書切り替え (自己署名 / 中間CA発行)
compose/
  otel/adot-collector-local.yaml     # ADOT Collector ローカル設定 (debug + Jaeger 出力)
  mysql/init.sql                     # appdb: XA_RECOVER_ADMIN 付与ほか初期化
  mysql/init-infdb.sh                # infdb / infuser の作成 (2 スキーマ目)
  svf-mock/mappings/report.json      # SVF 帳票サーバの WireMock スタブ
  ecs-metadata-mock/mappings/        # ECS Task Metadata Endpoint v4 の WireMock スタブ
  cwagent/cwagent-config.json        # CloudWatch Agent ローカル設定 (endpoint_override → mock)
  cwagent/verify-mount.sh            # cwagent の自己診断ラッパー (マウント/権限/設定パスを検証しログ出力)
  cwagent/ssm-config-entrypoint.sh   # SSM SecureString → CW_CONFIG_CONTENT 注入の偽装ラッパー
  cwagent/ssm/*.json                 # Parameter Store に登録する JSON の実体 (主設定 / 追加設定)
  cloudwatch-logs-mock/mappings/     # CloudWatch Logs API の WireMock スタブ (送信の偽装先)
  sqs/elasticmq.conf                 # SQS のローカル代替 (ElasticMQ) キュー/DLQ 設定
  lambda/app/handler.py              # Lambda 関数 (SQS→ALB→app-back を POST 呼び出し)
  lambda-esm/poller.py, Dockerfile   # SQS イベントソースマッピングの代替 (poller)
  alb/nginx.conf                     # ALB のローカル代替 (nginx L7 ルーティング / HTTP:80 + HTTPS:443)
  alb/rules/                         # ALB リスナールール (★差し替え可能★, variants/ に切り替えソース)
  alb/rules-tls/                     # HTTPS リスナーのルール (★差し替え可能★)
  alb/tls/                           # HTTPS リスナーに適用する証明書 (★差し替え可能★, variants/ あり)
  pki/gen-certs.sh, Dockerfile       # 自己署名 PKI 発行 (ルートCA→中間CA→サーバ証明書 / secure-api・ALB・MySQL)
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
  ssm/cwagent-config.json            # Parameter Store 登録用 CW Agent 設定 (→ CW_CONFIG_CONTENT)
  ssm/cwagent-config-mid.json        # 同 追加設定 (→ CW_CONFIG_CONTENT_MID)
  ssm/register-parameters.sh         # aws ssm put-parameter 登録スクリプト
  iam/task-role-policy.json          # タスクロール (X-Ray / CW メトリクス)
  iam/task-execution-role-policy.json# タスク実行ロール (ECR / logs / SSM / KMS)
terraform/                           # CW Agent 設定を SecureString で Parameter Store へ登録 + output
  main.tf, variables.tf, outputs.tf  # 登録内容・確認用 output (名前/ARN/型/ティア/版/sha256)
  terraform.tfvars.example           # → terraform.tfvars にコピーして app_name / env を設定
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

## 自己証明書 (cacert.crt) による HTTPS 検証 (secure-api / JDK・JBoss トラストストア / ALB)

HTTPS でのみ待ち受ける REST API サーバをテスト用の接続先として用意し、
**呼び出し元の front/back が自己証明書 `cacert.crt` を JDK と JBoss
(Elytron) の両トラストストアへ取り込むことで、アプリコードを無改変のまま REST API を
呼び出せる**ことを検証する。ALB 経由も同様に検証できる。

**★すでに発行済み / 連携された `cacert.crt` をそのまま投入できる。**
`compose/pki/provided/cacert.crt` に置くだけで `pki-init` は CA を新規発行せず、
その受領物をトラストアンカーとして全コンテナへ配る (置かなければ従来どおり自動発行)。

```bash
cp /path/to/受領した/cacert.crt compose/pki/provided/cacert.crt   # ★任意 (無ければ自動発行)
docker compose up -d --build
docker compose logs pki-init | grep 'MODE:'   # provided / generate のどちらで動いたか
./verify-tls.sh                 # 一括検証 (コンテナ内 + ホストから)
./verify-tls.sh quick           # JVM 経路のみ (短時間)
```

- `pki-init` が **`cacert.crt` (受領物 or 自動発行) → 各サーバ証明書** を named volume へ配置し全コンテナへ配る
  (トラストアンカーは `cacert.crt` **1 枚に一本化**。ルート CA + 中間 CA の 2 階層は廃止)
  - 受領物に秘密鍵 `cacert.key` が**無い**場合、受領 CA では署名できないためサーバ証明書は
    `local-test-ca` が発行する。front/back のトラストストアへ入る `cacert.crt` は常に**受領物そのもの**で、
    `tls-verifier` が SHA-256 を突き合わせて「まさにその受領物が取り込まれた」ことまで検証する
  - 受領物を差し替えると SHA-256 の変化を検知して自動で作り直す (`PKI_FORCE_REGENERATE` 不要)
- `secure-api` (WireMock, `--disable-http`) が **HTTPS でのみ** REST API を提供 (`:8543`)。★接続確認用のテスト接続先
- `app-front` / `app-back` の entrypoint が `keytool` で `cacert.crt` を **2 か所へ取り込む**
  - **JDK**: 同梱 cacerts のコピーへ追加し `-Djavax.net.ssl.trustStore` で JVM に指定 (パブリック CA の信頼は残る)
  - **JBoss**: `jboss-truststore.p12` を生成し、Elytron の `key-store` / `trust-manager` /
    `client-ssl-context` (`docker/cli/elytron-truststore.cli`) が参照する (自己証明書のみの専用ストア)
- `tls-probe.war` を front/back 両方に配備し、**その JVM 自身から** HTTPS 呼び出しを実行して確認できる
  (`trust=jdk` / `trust=jboss` / `trust=none` で経路を切り替え)
- `alb` に **HTTPS リスナー (`:9443`)** を追加。`/secure/*` は secure-api へ HTTPS 再暗号化で転送

```bash
# front の JVM から secure-api を直接 / ALB 経由で呼ぶ (JDK 側トラストストア)
curl -s "http://localhost:8080/tls-probe/check?target=direct&trust=jdk"   | jq .
curl -s "http://localhost:8180/tls-probe/check?target=alb&trust=jdk"      | jq .

# 同じ呼び出しを JBoss (Elytron) 側トラストストアで
curl -s "http://localhost:8080/tls-probe/check?target=direct&trust=jboss" | jq .

# 対照実験: 空のトラストストアでは必ず失敗する (502 が正しい)
curl -s "http://localhost:8080/tls-probe/check?target=direct&trust=none"  | jq .

# JDK 側 / JBoss 側の両トラストストアの中身 (stores.jdk / stores.jboss)
curl -s  http://localhost:8080/tls-probe/truststore | jq .

# ALB の証明書を切り替える (自己署名リーフ ⇄ cacert.crt 発行)。reload のみで即時反映
./alb-tls-cert.sh selfsigned | ca-issued | status
```

「自己証明書そのものをインポートする」「CA 証明書 (`cacert.crt`) をインポートする」の
**両パターンを同時に検証できる**よう、ALB 用に自己署名リーフと `cacert.crt` 発行の 2 種類を発行している。

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
- `cwagent` も front/back と同じく `group_add: 6302` を指定する。イメージが uid=0 で動くため
  DAC はバイパスされ実際には無くても読めてしまうが、それは **root 実行に依存して読めている**
  だけで、アプリ側 umask の変更やイメージの非 root 化で壊れる。EFS の POSIX 権限だけで
  読めている状態 (= アクセスポイント不使用の実 EFS と同じ前提) を保証するために明示する。

### cwagent の自己診断 (マウント/権限/設定パス)

CloudWatch Agent のイメージは診断ツールが乏しく `docker compose exec cwagent` での目視確認が
現実的でないため、**エージェント本体を exec する直前に同じコンテナ内で検証を実行し、
結果を stdout (= `docker compose logs` / ビルドログ) へ出力する**ラッパーを挟んでいる
(`compose/cwagent/verify-mount.sh` を `entrypoint` で指定)。

検証内容:

| 観点 | 判定方法 |
| --- | --- |
| volumes 指定が実際にマウントとして成立しているか | `/proc/self/mountinfo` に `/mnt/logs` が mount point として現れるか |
| 6301:6302 / mode 2775 を満たしているか | `stat` の owner/mode を期待値と比較。other ビットから「GID 6302 無しでも読めるか」も評価 |
| 設定の `file_path` のディレクトリ構造が実在するか | 親ディレクトリの存在と `readdir` 可否 |
| 対象ファイルを実際に読めるか | glob 展開して **`open(2)` を実行**して実測 (`[ -r ]` は uid=0 だと常に真になるため使わない) |
| エージェントがファイルを検知したか | tail オフセットの state ファイル (`.../logs/state`) の有無 |
| 送信の前提条件 | エンドポイントの名前解決・TCP 接続・認証情報ファイルの読み取り可否 |

起動直後 (`[boot]`) と、アプリがログを書き始めた後 (`[recheck N]`, 既定 20 秒間隔 × 5 回) に
評価する。`[boot]` の結果は healthcheck にも使われる (FAIL なら unhealthy)。

```bash
docker compose logs cwagent | grep cwagent-verify
```

#### `docker compose exec cwagent ls ...` は使えない

CloudWatch Agent のイメージには `ls` / `cat` が入っていない。そのため

```
OCI runtime exec failed: exec failed: unable to start container process:
exec: "ls": executable file not found in $PATH
```

は **「設定ファイルが無い」ではなく「`ls` が無い」** というだけであり、マウントの判定材料に
してはいけない (このエラーが返る時点で、コンテナ自体は起動している。停止中なら
`Container ... is not running` になる)。コンテナ内バイナリに依存しない確認手段:

```bash
# 1) マウントの成立とホスト側パス (docker inspect — コンテナ内バイナリ不要)
docker inspect cwagent --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}} (rw={{.RW}}){{"\n"}}{{end}}'

# 2) 中身の取り出し (docker cp — コンテナ内バイナリ不要)
docker cp cwagent:/etc/cwagentconfig/cwagent-config.json ./from-container.json

# 3) シェル組み込みだけで存在確認 (/bin/sh はイメージに存在する = entrypoint が動いている)
docker compose exec cwagent /bin/sh -c \
  'echo /etc/cwagentconfig/*; [ -f /etc/cwagentconfig/cwagent-config.json ] && echo EXISTS || echo MISSING'
```

自己診断ラッパー (`compose/cwagent/verify-mount.sh`) も同じ判定を `[cwagent-verify]` 行として
出力する。`entry: ...` 行が `/etc/cwagentconfig` の内容、
`cwagent-config.json がディレクトリになっている` の FAIL はホスト側パスを解決できず
Docker が空ディレクトリを作った状態 (= マウント失敗) を意味する。

- 送信の確認 (件数):

```bash
curl -s -X POST http://localhost:8480/__admin/requests/count \
  -H "Content-Type: application/json" \
  -d '{"method":"POST","url":"/","headers":{"X-Amz-Target":{"equalTo":"Logs_20140328.PutLogEvents"}}}'
```

### cwagent 設定を SSM Parameter Store (SecureString) から注入するパターン

上の `cwagent` は設定ファイルを `/etc/cwagentconfig` へマウントする方式だが、ECS タスク定義と同じ
**「Parameter Store の SecureString に入れた JSON 文字列を環境変数として受け取る」方式**も、
別サービス `cwagent-ssm` (`profiles: ssm-config`) として用意してある。
**既存の `cwagent` は無変更**で、通常の `docker compose up` の挙動も従来どおり。

```bash
docker compose up -d --build
docker compose --profile ssm-config up -d cwagent-ssm
./verify-cwagent-ssm.sh
```

- `CW_CONFIG_CONTENT` … エージェントが**デフォルトロード**する主設定
- `CW_CONFIG_CONTENT_MID` … 追加設定。**エージェントが自動で読むのは `CW_CONFIG_CONTENT` だけ**なので、
  ECS 側でも taskdef の `entryPoint` で `/etc/cwagentconfig/` へ materialize する必要がある
- 偽装しているのは「SSM から取得して環境変数へ入れる」「環境変数を設定ディレクトリへ流し込む」まで。
  **設定のマージと解釈は実エージェントがそのまま行う**ため、ローカルで成立した JSON は
  そのまま Parameter Store へ登録すれば ECS でも同じ実効設定になる
- ロググループを既存 cwagent (`/local/myapp/efs/*`) と分けてある (`/local/myapp/ssm/*`) ため、
  `cloudwatch-logs-mock` の request journal でどちらの経路の送信か区別できる

Parameter Store への登録と登録内容の確認は Terraform で行う:

```bash
cd terraform && cp terraform.tfvars.example terraform.tfvars   # app_name / env を設定
terraform init && terraform apply
terraform output parameter_summary          # 名前 / ARN / 型 / ティア / バージョン / サイズ / sha256
terraform output -raw verify_commands       # AWS CLI での確認コマンド
terraform output -raw ecs_taskdef_secrets   # taskdef へ貼る secrets ブロック
```

**実装・設定方法の詳細は [docs/CWAGENT-SSM-CONFIG.md](docs/CWAGENT-SSM-CONFIG.md) を参照。**

#### ログストリームが作られない / イベントが 0 件のとき

`cloudwatch-logs-mock` はスタブなので「ログストリーム」の実体は持たない。判定は WireMock の
request journal (受信件数) で行う。**どの API も 0 件 = 送信に失敗しているのではなく、
エージェントが送信自体を試みていない**状態であり、到達性 (名前解決 / TCP / 署名) ではなく
設定の読み込みとファイル検知を先に疑う。上から順に切り分ける:

| # | 確認 | 0 件の意味 |
| --- | --- | --- |
| 1 | `[cwagent-verify]` の `主設定ファイルが存在する` | 設定が注入できていない (未マウント / ディレクトリ化) → 収集対象ゼロ |
| 2 | `[cwagent-verify]` の `翻訳済み設定あり` | 設定は置かれているが translator が失敗 → `Under path :` / `E!` 行を確認 |
| 3 | `[cwagent-verify]` の `glob 一致 N 件` | `file_path` に一致するファイルが無い (アプリの出力先とのズレ) |
| 4 | `[cwagent-verify]` の `tail 状態ファイルあり` | 検知していない。ここまで OK なら送信側 (エンドポイント / 署名) を疑う |

1〜4 は `./verify-local.sh` の 13〜14 が自動で判定・再掲する。手動で見る場合:

```bash
docker compose logs cwagent | grep cwagent-verify          # 1〜4 の判定
docker compose logs cwagent | grep -E "Under path :|E!"    # translator / エージェントのエラー
docker cp cwagent:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json ./translated.json
```

## 置き換えプレースホルダー

`<AWS_REGION>` `<ACCOUNT_ID>` `<ECS_CLUSTER_NAME>` `<ECS_SERVICE_NAME>` `<APP_NAME>` `<ENV>`
`<IMAGE_TAG>` `<EAP_BASE_IMAGE>` `<RDS_PROXY_ENDPOINT>` `<VALKEY_ENDPOINT>` `<REPORT_ALB_DNS_NAME>`
`<DB_NAME>` `<DB_USER>` `<KMS_KEY_ID>`

詳細な設計説明・トラブルシューティングは [DESIGN.md](DESIGN.md) を参照。
