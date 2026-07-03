# 設計説明・トラブルシューティング

JBoss EAP 8.1 (UBI9/OpenJDK21) + ADOT Java Agent 自動計装 → X-Ray 構成の設計判断と運用手順。
ファイル一覧と使い方は [README.md](README.md) を参照。

---

## 1. 全体アーキテクチャ

### ECS/Fargate 本番構成 (1 タスク = 4 コンテナ)

```
ALB → app-front (EAP 8.1, :8080)
        │ REST (localhost)
        ├→ app-back (EAP 8.1, :8180 = port-offset 100)
        │     ├→ Aurora MySQL (RDS Proxy 経由, XA/2PC)
        │     ├→ ElastiCache for Valkey
        │     └→ SVF 帳票サーバ (内部 ALB 経由 REST)
        │
        ├→ adot-collector (:4318 OTLP 受信) → X-Ray
        └→ cwagent (:8125 statsd / :25888 EMF) → CloudWatch Metrics
```

awsvpc モードではタスク内の全コンテナが同一ネットワーク名前空間を共有するため、
コンテナ間通信はすべて `127.0.0.1` で完結する。front と back が同居するので
HTTP ポート衝突を避けるために back へ `-Djboss.socket.binding.port-offset=100` を適用する
(8080→8180、管理 9990→10090)。

### ローカル compose との対応

| ECS | compose | 等価性の担保 |
|---|---|---|
| app-front / app-back | 同じ | 同一 Dockerfile・同一 entrypoint・同一イメージ |
| adot-collector (awsxray) | adot-collector (debug + otlphttp/jaeger) | 同一イメージ・receiver/processor 同一、exporter のみ差し替え |
| X-Ray コンソール | Jaeger UI (:16686) | トレース可視化の代替 |
| Aurora + RDS Proxy | mysql:8.0.42 | XA_RECOVER_ADMIN を init.sql で付与 |
| ElastiCache for Valkey | valkey:8.0 | — |
| SVF 帳票サーバ (ALB) | WireMock (svf-mock) | REST スタブ |
| cwagent | なし | 送信先 CloudWatch がローカルに無いため除外 (トレース検証に不要) |

ECS ではタスク内 localhost 通信、compose では各サービスが別ネットワーク名前空間という
差分は、宛先をすべて環境変数 (`OTEL_EXPORTER_OTLP_ENDPOINT` / `BACK_BASE_URL` /
`DB_HOST` / `SVF_BASE_URL` 等) で切り替えることで吸収している。
イメージそのものは環境非依存 (次節)。

---

## 2. 主要な設計判断

### 2.1 ADOT Java Agent はビルド時同梱 (init container 方式ではなく)

`public.ecr.aws/aws-observability/adot-autoinstrumentation-java` からマルチステージで
`javaagent.jar` だけを `COPY` する。

- Fargate はホストボリューム共有に制約があり、init container + 共有ボリューム方式は
  タスク定義が複雑になる。ビルド時同梱ならイメージ単体で完結し、compose と ECS で差が出ない。
- Agent のバージョンは `ARG ADOT_JAVA_AGENT_VERSION` で固定 (v2.11.5)。更新はリビルドで行い、
  イメージタグで追跡可能。

### 2.2 -javaagent は JAVA_TOOL_OPTIONS で注入 (アプリ・EAP 設定は無改変)

`standalone.conf` の編集や WAR への依存追加を一切行わず、JVM 標準の `JAVA_TOOL_OPTIONS`
環境変数で agent を有効化する。entrypoint は既に `-javaagent` が含まれる場合は追加しない
(二重計装防止)。無効化はタスク定義の環境変数で `JAVA_TOOL_OPTIONS` を空にするだけで済む。

### 2.3 OTel 環境変数の設計

| 変数 | 本番値 | 理由 |
|---|---|---|
| `OTEL_PROPAGATORS` | `xray,tracecontext,baggage` | X-Ray ヘッダと W3C の両対応。front→back の REST 呼び出しでトレースが繋がる |
| `OTEL_TRACES_SAMPLER` | `parentbased_traceidratio` (ARG 0.10) | 本番 10% サンプリング。parentbased なので分散トレースの断片化なし |
| `OTEL_METRICS_EXPORTER` | `none` | メトリクスは cwagent (statsd/EMF) に集約し、二重送信とコスト増を回避 |
| `OTEL_LOGS_EXPORTER` | `none` | ログは awslogs ドライバで CloudWatch Logs へ |
| `OTEL_RESOURCE_ATTRIBUTES` | service.namespace 等 | X-Ray のグループ/フィルタ式で検索するキーを明示 |

ローカルは `parentbased_always_on` (全量) に切り替えて検証の見落としを防ぐ。
entrypoint のデフォルトは「未設定時のみ補完」なので、タスク定義・compose の値が常に優先される。

### 2.4 Collector 設定は SSM Parameter Store から注入

ADOT Collector 公式イメージは `AOT_CONFIG_CONTENT` 環境変数に YAML 本文が入っていると
それを設定として使う。タスク定義の `secrets` で SSM パラメータを注入することで、
設定変更をイメージ再ビルドなしで実施できる (反映は `--force-new-deployment`)。

パイプラインは `memory_limiter → resourcedetection/ecs → resource → batch`:

- `memory_limiter` は必ず先頭 (OOM 防止)
- `resourcedetection/ecs` が ECS メタデータから `aws.ecs.*` / `cloud.*` を自動付与
- `awsxray` exporter の `indexed_attributes` で annotation へ昇格する属性を明示列挙
  (`index_all_attributes: true` はコスト増のため不採用)

### 2.5 XA データソース (2PC) の設計

ビルド時に `jboss-cli.sh --file=` (embed-server) で `standalone.xml` へ焼き込む。
接続先・認証情報は `${env.DB_HOST}` 等の式で「起動時の環境変数」を参照するため、
**イメージは dev/stg/prod/compose すべて同一**で、環境差はタスク定義/compose の env だけ。

MySQL 固有の考慮:

- `PinGlobalTxToPhysicalConnection=true` — MySQL は同一 XID の XA START〜PREPARE を
  同一物理コネクションで行う必要があるため必須
- `XA_RECOVER_ADMIN` 権限 — EAP のリカバリマネージャが `XA RECOVER` を発行する。
  Aurora 側でも DBA 作業として `GRANT XA_RECOVER_ADMIN ON *.* TO ...` が必要 (init.sql と同等)
- `node-identifier` — `${jboss.tx.node.id:changeme}` とし、起動時に `-Djboss.tx.node.id` で注入。
  同一 DB を共有する全 EAP インスタンスで一意でないと、他ノードの in-doubt トランザクションを
  誤ってロールバックする事故につながる。タスク定義では `<APP_NAME>-<ENV>-front` / `-back` を設定
  (複数タスクにスケールアウトする場合は後述のトラブルシューティング参照)

### 2.6 IAM の最小権限

- **タスクロール** (アプリ実行時): X-Ray への書き込み + サンプリング API、
  cwagent 用の `PutMetricData` (namespace 条件付き) と EMF ロググループ
- **タスク実行ロール** (起動時): ECR pull (リポジトリ限定)、awslogs、
  `ssm:GetParameters` (3 パラメータに限定)、SecureString 復号用 `kms:Decrypt`
  (`kms:ViaService` で SSM 経由に限定)

---

## 3. ECS デプロイ手順

```bash
# 1. イメージビルド & ECR push (docker/ 直下で)
docker build -f front/Dockerfile --build-arg EAP_BASE_IMAGE=<EAP_BASE_IMAGE> \
  -t <ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<APP_NAME>-front:<IMAGE_TAG> .
docker build -f back/Dockerfile  --build-arg EAP_BASE_IMAGE=<EAP_BASE_IMAGE> \
  -t <ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<APP_NAME>-back:<IMAGE_TAG> .
# (aws ecr get-login-password ... で認証後 push)

# 2. SSM パラメータ登録 (ecs/ssm/ で)
AWS_REGION=... APP_NAME=... ENV=... ./register-parameters.sh

# 3. IAM ロール作成 (ecs/iam/ のポリシーをアタッチ)

# 4. タスク定義登録 & サービス更新
aws ecs register-task-definition --cli-input-json file://ecs/taskdef.json
aws ecs update-service --cluster <ECS_CLUSTER_NAME> --service <ECS_SERVICE_NAME> \
  --task-definition <APP_NAME>-<ENV>-task --force-new-deployment
```

確認: X-Ray コンソール → トレース → フィルタ式
`annotation.service.namespace = "<APP_NAME>" AND annotation.deployment.environment = "<ENV>"`

---

## 4. トラブルシューティング

### X-Ray / Jaeger にトレースが出ない

切り分けは「アプリ → Collector → X-Ray」の順で行う。

1. **Agent が動いているか**: アプリコンテナログの先頭付近に
   `[otel.javaagent]` の起動バナーが出るか。出ない場合は entrypoint ログの
   `JAVA_TOOL_OPTIONS=` に `-javaagent:/opt/adot/aws-opentelemetry-agent.jar` が
   含まれているか確認。
2. **Collector が受信しているか**: `docker compose logs adot-collector` (ローカル) /
   CloudWatch Logs の adot ストリーム (ECS) に `TracesExporter` のログが出るか。
   出ない場合はアプリ側の `OTEL_EXPORTER_OTLP_ENDPOINT` (compose は
   `http://adot-collector:4318`、ECS は `http://127.0.0.1:4318`) を確認。
3. **X-Ray へ送れているか** (ECS のみ): Collector ログに `AccessDenied` /
   `UnrecognizedClientException` があればタスクロール、`region` 設定ミスなら
   exporter の region を確認。
4. **サンプリングで落ちていないだけ**: 本番は 10%。検証時は一時的に
   `OTEL_TRACES_SAMPLER_ARG=1.0` にするか、リクエストを増やす。

### front と back のトレースが繋がらない (別トレースになる)

- `OTEL_PROPAGATORS` に `tracecontext` (または `xray`) が両コンテナで入っているか。
- front→back の HTTP クライアントが計装対象ライブラリか
  (Apache HttpClient / JAX-RS Client 等は自動計装対象)。
- back 側が `parentbased_*` サンプラーになっているか (`always_off` だと子が消える)。

### JBoss EAP が起動しない / healthcheck で落ちる

- `start_period` は 120s 確保済み。EAP + agent の初回起動は 60–90s かかることがある。
- entrypoint は `DB_*` 未設定だと fail-fast する。ログの `[entrypoint]` 行を確認。
- ビルド時 CLI が失敗する場合: ベースイメージの `JBOSS_HOME` が `/opt/server` か、
  `standalone.xml` が存在するかを確認 (Galleon プロビジョニングの layer 構成による)。

### XA / 2PC 関連

| 症状 | 原因と対処 |
|---|---|
| `XAER_RMERR` が XA RECOVER で発生 | DB ユーザーに `XA_RECOVER_ADMIN` が無い。GRANT する |
| `XAER_NOTA` / prepare 失敗 | `PinGlobalTxToPhysicalConnection=true` が入っているか確認 (RDS Proxy の多重化と相性が悪いため必須) |
| 他ノードのトランザクションが勝手にロールバックされる | `node-identifier` が重複。`TX_NODE_ID` をインスタンスごとに一意化する。ECS でサービスを複数タスクにスケールする場合は、固定値ではなくタスク ID 由来の値 (entrypoint のデフォルト `front-$(hostname)` はコンテナ ID 由来なので一意) を使うこと。ただしタスク入れ替えで ID が変わると in-doubt トランザクションのリカバリが引き継がれない点はトレードオフ |
| RDS Proxy 経由で XA が失敗する | RDS Proxy はセッションピン留めが発生する。`PinGlobalTxToPhysicalConnection` と併せて、Proxy のピン留めメトリクス (`DatabaseConnectionsCurrentlySessionPinned`) を監視 |

### SSM / タスク起動関連

- `ResourceInitializationError: unable to pull secrets` → タスク実行ロールの
  `ssm:GetParameters` / `kms:Decrypt` とパラメータ名の一致を確認。
- SSM String は standard tier で 4KB 上限。Collector 設定が超える場合は
  advanced tier (8KB) にする (`register-parameters.sh` は Intelligent-Tiering 指定済みで自動昇格)。
- パラメータを更新しても反映されない → secrets はタスク起動時にのみ解決される。
  `--force-new-deployment` で新タスクを起動する。

### ローカル compose 固有

- `EAP_BASE_IMAGE` が pull できない → 社内レジストリへの `docker login` を確認。
- Jaeger UI にサービスが出ない → まず `./verify-local.sh` を実行。Collector の
  debug exporter ログにスパンが出ていれば Collector→Jaeger 間、出ていなければ
  アプリ→Collector 間の問題。
- ポート衝突 (3306/6379/8080 等) → ホスト側で既存のプロセスが使用していないか確認し、
  compose.yaml の `ports` の左側 (ホスト側) だけ変更する。
