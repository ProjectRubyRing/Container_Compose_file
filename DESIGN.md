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
        │     ├→ Aurora MySQL 8.4 (RDS Proxy 経由, XA/2PC)
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
| app-front / app-back (コンテナ名) | frontend / backend (compose サービス名) | 同一 Dockerfile・同一 entrypoint・同一イメージ。compose 側だけ役割が分かる名前にしてあり、ECS 側の識別子 (コンテナ名・ロググループ `/ecs/.../app-front`・偽装 EFS 上の `app-front*.log`) は taskdef と一致させたまま据え置く |
| ALB ターゲットグループのヘルスチェック | alb-healthcheck (ELB-HealthChecker/2.0 の偽装) | `interval` / `timeout` / `matcher` / `healthy・unhealthy threshold` と `initial → healthy / unhealthy` の遷移まで ALB と同じ規則で判定する。詳細は [docs/ALB-HEALTHCHECK.md](docs/ALB-HEALTHCHECK.md) |
| adot-collector (awsxray) | adot-collector (debug + otlphttp/jaeger) | 同一イメージ・receiver/processor 同一、exporter のみ差し替え |
| X-Ray コンソール | Jaeger UI (:16686) | トレース可視化の代替 |
| Aurora MySQL 8.4 + RDS Proxy | mysql:8.4.7 | XA_RECOVER_ADMIN を init.sql で付与。Connector/J 9.7.0 (静的モジュール)。TLS は pki-init 発行の CA 発行証明書 + 平文拒否で RDS Proxy 相当にそろえ、本番と同じ `sslMode=VERIFY_IDENTITY` で検証する。詳細は [docs/MYSQL-8.4-AURORA-UPGRADE.md](docs/MYSQL-8.4-AURORA-UPGRADE.md) / [docs/RDS-PROXY-TLS.md](docs/RDS-PROXY-TLS.md) |
| ElastiCache for Valkey | valkey:8.0 | — |
| SVF 帳票サーバ (ALB) | WireMock (svf-mock) | REST スタブ |
| EFS (/mnt/logs, /mnt/data。アクセスポイント不使用) | efs-mock + named volume | UID 6301 / GID 6302, mode 2775 (setgid) で初期化。front/back は `group_add: 6302` で書き込み。ホスト側の権限変更は不要 |
| cwagent (ログ転送) | cwagent (同一イメージ) | 設定の `logs.endpoint_override` で送信先のみ cloudwatch-logs-mock へ差し替え (認証情報はダミー) |
| ECS Task Metadata Endpoint v4 (`ECS_CONTAINER_METADATA_URI_V4` をタスク内の**全コンテナ**へ注入) | WireMock (ecs-metadata-mock) | front / back / adot-collector / cwagent (+ cwagent-ssm) の**すべて**にこの変数を与え、コンテナごとの `DockerId` まで taskdef と一致させる。1 つでも未設定だと、そのコンテナは ECS エージェントのリンクローカルアドレス (`169.254.170.2` 等) へ直接アクセスして失敗する |
| cwagent の設定注入 (SSM SecureString → `CW_CONFIG_CONTENT` / `CW_CONFIG_CONTENT_MID`) | cwagent-ssm (同一イメージ, `profiles: ssm-config`) | 「SSM 取得 + KMS 復号」と「環境変数 → `/etc/cwagentconfig` への materialize」だけを偽装し、**設定のマージと解釈は実エージェントに行わせる**。詳細は [docs/CWAGENT-SSM-CONFIG.md](docs/CWAGENT-SSM-CONFIG.md) |
| CloudWatch Logs | WireMock (cloudwatch-logs-mock) | PutLogEvents 受信スタブ。request journal で送信内容を確認 |
| AWS Private CA (ACM PCA) / 社内 CA | pki-init (openssl) | 自己証明書 `cacert.crt` → 各サーバ証明書を named volume で共有。トラストアンカーは `cacert.crt` 1 枚。**`compose/pki/provided/cacert.crt` に受領済みの証明書を置けばそれをそのまま使う** (無ければ自己署名 CA を自動発行)。鍵なしの受領物では発行専用の `local-test-ca` を併用する |
| CA 証明書の配布 (S3 / Secrets Manager / 社内配布サーバ → CI がビルド前に取得) | pki-init が `compose/pki/export/` へ**出力** | named volume は `docker build` から見えないため、`cacert.crt` をホストへも書き出す。ベースイメージと同じ **build secret** (`--mount=type=secret,id=cacert`) でビルドへ渡せるほか、そのまま `compose/pki/provided/` へ置いて CA を固定できる。詳細は [docs/TLS-SELF-SIGNED-ALB.md](docs/TLS-SELF-SIGNED-ALB.md) 3 章 |
| 自己証明書で HTTPS を要求する外部 API | WireMock (secure-api, `--disable-http`) | HTTPS のみ listen。★接続確認用のテスト接続先。front/back は `cacert.crt` を **JDK と JBoss(Elytron) の両トラストストア**へ取り込んで呼び出す。詳細は [docs/TLS-SELF-SIGNED-ALB.md](docs/TLS-SELF-SIGNED-ALB.md) |
| ALB の HTTPS リスナー + ACM 証明書 | alb (nginx) の `listen 443 ssl` | 証明書は自己署名リーフ / `cacert.crt` 発行を `./alb-tls-cert.sh` で切り替え。`/secure/*` はターゲットへ HTTPS 再暗号化 |
| ECS Exec (`aws ecs execute-command` + SSM チャネル) | ecs-exec (docker exec に読み替える偽装 CLI) | 入口・引数・出力・例外名を実物にそろえ、接続先は `tasks.json` で `app-front → frontend` / `app-back → backend` と対応づける。ファイル投入も実運用と同じ「base64 をコマンド行に載せる」方式。詳細は [docs/ECS-EXEC.md](docs/ECS-EXEC.md) |

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

JDBC ドライバは `module add` の自動生成をやめ、`docker/modules/com/mysql/main/module.xml`
として明示管理する静的モジュール (`com.mysql`) を Dockerfile で配置する。
Aurora MySQL 8.4 / MySQL 8.4.7 に合わせて **Connector/J 9.7.0** を採用
(詳細は [docs/MYSQL-8.4-AURORA-UPGRADE.md](docs/MYSQL-8.4-AURORA-UPGRADE.md))。

MySQL 固有の考慮:

- `PinGlobalTxToPhysicalConnection=true` — MySQL は同一 XID の XA START〜PREPARE を
  同一物理コネクションで行う必要があるため必須
- `XA_RECOVER_ADMIN` 権限 — EAP のリカバリマネージャが `XA RECOVER` を発行する。
  Aurora 側でも DBA 作業として `GRANT XA_RECOVER_ADMIN ON *.* TO ...` が必要 (init.sql と同等)
- `SslMode` — 既定 `VERIFY_IDENTITY` (`${env.DB_SSL_MODE}` で上書き可)。接続先は本番・ローカルとも
  「CA 発行のサーバ証明書を提示し TLS を必須とするエンドポイント」(RDS Proxy / TLS 設定済み mysql
  コンテナ) のため、チェーンとホスト名まで検証する。**サーバ証明書を発行した CA を JVM トラストストアへ
  取り込むことが前提** (ローカルは pki-init、本番は Amazon RDS の CA バンドル)。
  詳細は [docs/RDS-PROXY-TLS.md](docs/RDS-PROXY-TLS.md)
- `node-identifier` — `${jboss.tx.node.id:changeme}` とし、起動時に `-Djboss.tx.node.id` で注入。
  同一 DB を共有する全 EAP インスタンスで一意でないと、他ノードの in-doubt トランザクションを
  誤ってロールバックする事故につながる。タスク定義では `<APP_NAME>-<ENV>-front` / `-back` を設定
  (複数タスクにスケールアウトする場合は後述のトラブルシューティング参照)

### 2.6 IAM の最小権限

- **タスクロール** (アプリ実行時): X-Ray への書き込み + サンプリング API、
  cwagent 用の `PutMetricData` (namespace 条件付き) と EMF ロググループ、
  ECS Exec 用の `ssmmessages:*` 4 つ (`ECSExecSSMMessages`)。
  ECS Exec は SSM のチャネルを**タスク側から**張るため、これはタスクロールに要る
  (タスク実行ロールではない)。使わない構成ならステートメントごと削除してよい
- **タスク実行ロール** (起動時): ECR pull (リポジトリ限定)、awslogs、
  `ssm:GetParameters` (パラメータを列挙して限定)、SecureString 復号用 `kms:Decrypt`
  (`kms:ViaService` で SSM 経由に限定)

### 2.7 CloudWatch Agent 設定も SSM Parameter Store から注入 (SecureString)

Collector と同じ考え方で、CW Agent 設定もタスク定義の `secrets` から注入する。
ただし 2.4 の `AOT_CONFIG_CONTENT` と違い、**複数パラメータに分割する場合に一手間要る**。

- **`CW_CONFIG_CONTENT` (主設定)** はエージェントがデフォルトロードする。
- **`CW_CONFIG_CONTENT_MID` (追加設定)** のような追加の環境変数は、
  **エージェントが素のままでは読まない**。エージェントがコンテナ実行時に見るのは
  `/etc/cwagentconfig` (`--input-dir`) であり、そこに置かれた JSON が**すべてマージ**される。
  そのため taskdef の `entryPoint` で「環境変数 → `/etc/cwagentconfig/NN-*.json`」の
  materialize を挟み、エージェント本体のマージ機構に載せている。
  - 数値プレフィクス (`00-` / `10-`) がマージ順になる
  - materialize 後に `unset` する。エージェント側にも `CW_CONFIG_CONTENT` を読む経路が
    あるため、残すと同じ設定が二重に読まれ `collect_list` が重複しうる
  - `/etc/cwagentconfig` はタスクレベル volume でマウントする
    (イメージに `mkdir(1)` が無い場合があるため、ディレクトリの存在を外側で保証する)
- **分割する動機**: パラメータのサイズ上限 (Standard 4KB / Advanced 8KB) の回避と、
  設定の管理主体を分けること (基盤共通設定 / ミドルウェア個別設定)。
- **SecureString にする理由**: 値がタスク定義やコンソールの環境変数一覧に平文で残らない。
  復号はタスク実行ロールが起動時に行うため、アプリ側の実装は変わらない。
- 登録は `terraform/` (JSON の妥当性検証・サイズ上限チェック・確認用 output 付き)。
  `ecs/ssm/register-parameters.sh` でも `CWAGENT_SECURESTRING=1` で同じ 2 本を登録できるが、
  **二重管理になるためどちらか一方に寄せる**。
- ローカル compose では `cwagent-ssm` サービス (`profiles: ssm-config`) が同じ経路を偽装する。
  偽装するのは「SSM 取得 + 復号」と「環境変数 → 設定ディレクトリへの流し込み」までで、
  **マージと設定解釈は実エージェントに行わせる**。これにより
  「ローカルで成立した JSON = ECS でも同じ実効設定」が担保される。
  既存の `cwagent` (ファイルマウント方式) は変更していないので、両方式を並べて比較できる。

詳細は [docs/CWAGENT-SSM-CONFIG.md](docs/CWAGENT-SSM-CONFIG.md)。

### 2.8 自己証明書 (cacert.crt) はホストへ出力し、build secret でイメージへ渡す

`pki-init` が配備した `cacert.crt` は named volume (`pki`) に置かれるが、
**named volume の中身は `docker build` からは見えない**。
一方、社内標準ベースイメージは BuildKit の build secret 経由で
「ビルドコンテキスト上の所定のディレクトリに置いた `cacert.crt`」を受け取り、
JVM と JBoss EAP のトラストストアへ取り込む作りになっている。
この 2 つを繋ぐため、`pki-init` は同じ `cacert.crt` を
**ホストの `compose/pki/export/` へも書き出す**。

- **出力は PEM 1 枚をそのまま**。中身の書き換えもリネームもしないので、
  **`compose/pki/provided/` へコピーするだけでそのまま入力として使える**
  (自動発行した CA を「受領物」として固定できる = 入力と出力が往復する)。
  `cacert.key` も出力するのは、置き直したときに「受領 CA が全サーバ証明書を発行する」
  構成を維持するため (`PKI_EXPORT_KEY=0` で抑止できる)。
- **出力は毎回まるごと作り直す**。特に `cacert.key` は `provided` モードの分岐そのものを
  変えるため、古い鍵が残って証明書と食い違う (= `pki-init` の起動失敗) 事故を防ぐ。
- **ビルドへの受け渡しは `COPY` ではなく `--mount=type=secret`**。ビルド中だけ tmpfs に
  マウントされ、イメージのレイヤーにもビルドキャッシュにも残らない。
  ベースイメージが採っている方式と同じにすることで、ローカルで検証した手順が
  そのままベースイメージのビルドにも通用する。
- **`compose.build-secret.yaml` に分離した理由**: compose の `secrets(file:)` は
  参照先ファイルが無いと `build` が失敗する。`cacert.crt` は `pki-init` を起動して
  初めて出力されるため、本体の `compose.yaml` に入れるとまっさらな clone での
  `docker compose up -d --build` が通らなくなる。
- **Dockerfile 側は secret が無ければ何もしない**ため、この追加で既存のビルド手順は
  一切壊れない。ビルド時取り込みと entrypoint の実行時取り込みは併用でき、
  `PKI_TRUST_DIR` に証明書が無ければ実行時取り込みはスキップされて
  **イメージへ焼き込んだトラストストアがそのまま使われる**
  (= `pki` volume 無しでも HTTPS が通る。ECS で volume を持たない構成に近い)。

詳細は [docs/TLS-SELF-SIGNED-ALB.md](docs/TLS-SELF-SIGNED-ALB.md) 3 章 /
[compose/pki/export/README.md](compose/pki/export/README.md)。
一覧表は [docs/PKI-CACERT-EXPORT.xlsx](docs/PKI-CACERT-EXPORT.xlsx) (Excel, 8 シート)。

### 2.9 ECS Exec は「コマンド体系」を偽装し、チャネルだけ docker exec に読み替える

ECS Exec の実体は AWS CLI → ECS API → SSM の制御/データチャネル →
コンテナ内の ExecuteCommandAgent という多段構成で、ローカルには SSM が無い。
そこで **利用者から見える層 (コマンド・引数・応答・例外) を実物に合わせ、
運ぶ層だけを `docker exec` に置き換える** 方針を採った。

- **なぜ `docker compose exec frontend bash` で済ませないのか**: それは compose 固有の
  操作で、実 AWS には対応物が無い。手順書・訓練・切り分けの練習には
  「本番でそのまま打てるコマンド」であることに意味がある。`ecs-exec` の
  補助コマンドも、実行前に等価な `aws ecs execute-command` を必ず表示する
- **`docker cp` を使わない**: 実 ECS Exec に転送機能が無い以上、それを使えると
  誤解させる偽装は有害になる。`ecs-exec put` / `get` は実運用と同じ
  「base64 をコマンド行へ載せて分割送信 → コンテナ側でデコード → sha256 照合」
  を自動化しているだけで、出力されるコマンドはそのまま実 AWS でも通る
- **失敗の再現を等価性の要にした**: ECS Exec の実務上の難所は「入れないときに
  何が原因か」の切り分けにある。`enableExecuteCommand` 無効・エージェント未起動・
  クラスター名の指定漏れ・コンテナ名の取り違えを、実物と同じ例外名
  (`InvalidParameterException` / `TargetNotConnectedException` /
  `ClusterNotFoundException`) で再現できるようにした
- **接続先は `tasks.json` に外出し**: クラスター名・タスク ID・コンテナ名・
  `runtimeId` は `ecs-metadata-mock` のタスクメタデータと同じ値にしてあり、
  ECS のコンテナ名 (`app-front` / `app-back`) から compose サービス
  (`frontend` / `backend`) への対応もここだけで決まる
- **docker ソケットを渡すのはこのサービスだけ**。「タスクの中へ入れる」という
  ECS Exec の性質そのものであり、テスト環境限定で使う前提

詳細は [docs/ECS-EXEC.md](docs/ECS-EXEC.md)。

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
#    CW Agent 設定 (CW_CONFIG_CONTENT / CW_CONFIG_CONTENT_MID) は Terraform でも登録できる:
#      cd terraform && cp terraform.tfvars.example terraform.tfvars && terraform init && terraform apply
#      terraform output parameter_summary        # 登録内容の確認
#      terraform output -raw ecs_taskdef_secrets # taskdef へ貼る secrets ブロック
#    (register-parameters.sh との二重管理を避け、どちらか一方に寄せること)

# 3. IAM ロール作成 (ecs/iam/ のポリシーをアタッチ)

# 4. タスク定義登録 & サービス更新
aws ecs register-task-definition --cli-input-json file://ecs/taskdef.json
aws ecs update-service --cluster <ECS_CLUSTER_NAME> --service <ECS_SERVICE_NAME> \
  --task-definition <APP_NAME>-<ENV>-task --force-new-deployment

# 5. (任意) ECS Exec を使う場合。タスク定義ではなく★サービス★のパラメータで、
#    有効化しても既存タスクには効かないため置き換えが要る
#    (タスクロールの ssmmessages:* は ecs/iam/task-role-policy.json に入っている)
aws ecs update-service --cluster <ECS_CLUSTER_NAME> --service <ECS_SERVICE_NAME> \
  --enable-execute-command --force-new-deployment
aws ecs execute-command --cluster <ECS_CLUSTER_NAME> --task <TASK_ID> \
  --container app-front --interactive --command "/bin/bash"
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
| `XAER_INVAL: Invalid arguments (or unsupported command)` | **トランザクションの中断 (suspend) が原因**。MySQL は `XA END ... SUSPEND` / `XA START ... RESUME` を実装しておらず、XA トランザクション中に Narayana が `XAResource.end(xid, TMSUSPEND)` を発行すると必ずこのエラーになる。XA コネクションを enlist したまま `@TransactionAttribute(REQUIRES_NEW / NOT_SUPPORTED / NEVER)` のメソッドを呼ぶ、`TransactionManager.suspend()` を呼ぶ、といった箇所を洗い出し、**DB アクセスを中断の前に完了させる**か、`REQUIRES_NEW` の呼び出しを同一トランザクション外へ出す。MySQL 側の設定では回避できない (下の検証結果を参照) |
| `XAER_RMERR` が XA RECOVER で発生 | DB ユーザーに `XA_RECOVER_ADMIN` が無い。GRANT する |
| `XAER_NOTA` / prepare 失敗 | `PinGlobalTxToPhysicalConnection=true` が入っているか確認 (RDS Proxy の多重化と相性が悪いため必須) |
| 他ノードのトランザクションが勝手にロールバックされる | `node-identifier` が重複。`TX_NODE_ID` をインスタンスごとに一意化する。ECS でサービスを複数タスクにスケールする場合は、固定値ではなくタスク ID 由来の値 (entrypoint のデフォルト `front-$(hostname)` はコンテナ ID 由来なので一意) を使うこと。ただしタスク入れ替えで ID が変わると in-doubt トランザクションのリカバリが引き継がれない点はトレードオフ |
| RDS Proxy 経由で XA が失敗する | RDS Proxy はセッションピン留めが発生する。`PinGlobalTxToPhysicalConnection` と併せて、Proxy のピン留めメトリクス (`DatabaseConnectionsCurrentlySessionPinned`) を監視 |

#### MySQL 8.4.7 + Connector/J 9.7.0 での XA 操作の実測結果

どの操作がどのエラーになるかを実機で確認した結果 (切り分けの基準にする):

| XAResource の呼び出し | 発行される SQL | 結果 |
|---|---|---|
| `end(xid, TMSUSPEND)` | `XA END ... SUSPEND` | **XAER_INVAL** ← 中断は非対応 |
| `start(xid, TMRESUME)` (中断後の再開) | `XA START ... RESUME` | **XAER_INVAL** |
| `start(xid, TMJOIN)` | `XA START ... RESUME` (Connector/J が読み替え) | 分岐が IDLE なら成功 |
| `start`/`end`/`prepare`/`commit` (中断なしの通常 2PC) | — | 成功 |
| 同一 gtrid・別 bqual を別コネクションで 2 ブランチ | — | 成功 (2PC 本来の形) |
| 同一コネクションで 2 ブランチ目を `start` | — | XAER_RMFAIL (ACTIVE state) |
| gtrid または bqual が **65 byte 以上** | — | XAER_RMFAIL (XAER_INVAL ではない) |

つまり **XAER_INVAL が出たら、まず「トランザクションの中断」を疑う**。
XID 長超過 (`node-identifier` / `TX_NODE_ID` が長すぎる場合) は XAER_RMFAIL になるため区別できる。
なお gtrid・bqual の上限は各 64 byte なので、`TX_NODE_ID` は短く保つこと
(ECS の `<APP_NAME>-<ENV>-front` が長くなりすぎないよう注意)。

### DB の TLS 関連

| 症状 | 原因と対処 |
|---|---|
| mysql のログに `MY-010068 CA certificate ca.pem is self signed.` / `MY-013602 Channel mysql_main configured to support TLS.` | **どちらもエラーではない** (mysqld 起動時の Warning と通知)。前者は自己署名証明書の自動生成が止まっていないサイン。`docker compose down -v` で作り直す。詳細は [docs/RDS-PROXY-TLS.md](docs/RDS-PROXY-TLS.md) |
| `PKIX path building failed` でプール初期化に失敗 | `SslMode=VERIFY_*` なのにサーバ証明書の CA が JVM トラストストアに無い。ローカルは pki-init の CA、本番は Amazon RDS の CA バンドル (`global-bundle.pem`) を `PKI_TRUST_DIR` へ配置する。entrypoint が起動時に警告を出す |
| `No subject alternative names matching ...` | 証明書の SAN に `DB_HOST` の値が含まれていない。ローカルは `PKI_RDS_PROXY_SAN` を直して再発行、本番は RDS Proxy のエンドポイント FQDN を `DB_HOST` に指定する |
| `ERROR 3159 Connections using insecure transport are prohibited` | `require_secure_transport=ON` / RDS Proxy の "Require TLS" が有効。クライアント側で TLS を有効にする (想定どおりの挙動) |
| `Public Key Retrieval is not allowed` | 平文接続で `caching_sha2_password` を使ったとき。TLS が張れていないので上記を先に解決する |

### 自己証明書 HTTPS (secure-api / ALB) 関連

`tls-probe` は **JVM から見た** 接続可否を返すため、失敗したとき
「トラストストアに CA が入っていない」のか「そもそも宛先へ届いていない」のかの
切り分けが要る。コンテナ内の `curl` から同じ経路をたどると早い。

姉妹リポジトリの `Container_Compose_Build_Push_v2_from_Codex/build_and_verify.sh` を
`--keep-container-mode logs` で起動すると、操作メニューに**証明書チェック**が出る
(表示条件はコンテナ内に `curl` + `keytool` があり、JVM トラストストアと `https://`
環境変数の両方を持つこと。frontend / backend が該当し、mysql 等には出ない)。
選択後の入力は不要で、次を自動検出して一度に回す。

| 検出対象 | 検出元 |
|---|---|
| トラストストア | 起動中 JVM の `-Djavax.net.ssl.trustStore` → `*TRUSTSTORE*` 環境変数 (JDK 側と JBoss 側の両方) |
| ↑の内訳 | JBoss 側は compose.yaml の `JBOSS_TRUSTSTORE_FILE` から。JDK 側は entrypoint が `JAVA_TOOL_OPTIONS` へ足すため `docker exec` の環境には出ず、`/proc/<pid>/environ` 経由で拾う |
| パスワード | `-Djavax.net.ssl.trustStorePassword` → `*_PASSWORD` 環境変数 → `changeit` → 無し |
| 接続先 | `https://` を値に持つ環境変数 (`SECURE_API_URL` / `SECURE_API_VIA_ALB_URL`) |
| CA 証明書 | `${PKI_TRUST_DIR}/*.crt` |

読み方は次のとおり。

- **CA 証明書の SHA-256 照合が `[FAIL]`** → `cacert.crt` がそのストアに入っていない。
  entrypoint の `keytool -importcert` が失敗している。表示される `keytool -importcert`
  の実行例で手当てできる
- **接続が `curl exit 60`** → ストアに CA が無い / サーバ証明書のチェーンが違う
- **`curl exit 6` / `7`** → 名前解決・到達性の問題であってトラストストアは無関係。
  compose ネットワークと `secure-api` の起動状態を見る
- **対照テスト (`--cacert` 無し) が `[WARN]` で成功** → 宛先がパブリック CA でも検証できており、
  自己証明書の取り込みを検証できていない。`cacert.crt` の配布経路を疑う

### ALB ヘルスチェック関連 (frontend / backend)

ヘルスチェックは 2 系統あり、**どちらの話をしているか**を先に区別する。

| | 定義 | 実行場所 | 判定材料 |
|---|---|---|---|
| コンテナ | タスク定義の `healthCheck` (= compose の `healthcheck:`) | コンテナの中 | コマンドの終了コード |
| ALB | ターゲットグループのヘルスチェック設定 | コンテナの外 (`alb-healthcheck` が代替) | HTTP ステータスコードと連続回数 |

ローカルでは `alb-healthcheck` サービスが後者を `ELB-HealthChecker/2.0` として再現し、
`initial` / `healthy` / `unhealthy` と ALB と同じ理由コードを導出する。
`build_and_verify.sh --keep-container-mode logs` の操作メニューには
**ALB ヘルスチェック確認 (ステータスコード / 成功失敗判定)** が出る
(表示条件は `alb-healthcheck` が起動しており、選んだサービスが `targets.json` の
ターゲットであること。`frontend` / `backend` と偽装サービス自身が該当する)。

| 症状 | 原因と対処 |
|---|---|
| コンテナは `healthy` なのに ALB では `unhealthy` | ALB の `path` / `matcher` が実際の応答と合っていない。`docker compose logs alb-healthcheck` の `status=` を見て `compose/alb-healthcheck/targets.json` を直す (例: ルートが 302 を返すなら `matcher` を `200-399` に) |
| いつまでも `initial` | `healthy_threshold_count` 回の連続成功に達していない (既定 5 回 × 30 秒 = 最短 150 秒)。ALB も同じ挙動 |
| `unhealthy` から戻らない | 復帰にも**連続成功**が必要。ログの `streak=success:n/failure:m` で連続回数を確認する |
| 戻り値 `28` / `Target.Timeout` が続く | 応答が `timeout_seconds` より遅い。EAP 起動途中ならそのまま待つ (ALB 側に `start_period` 相当の設定はなく、本番は ECS サービスの health check grace period で吸収する) |
| 戻り値 `6` / `7` | 名前解決・接続の問題でヘルスチェック設定は無関係。ターゲットの起動状態と compose ネットワークを見る |
| メニューに項目が出ない | `alb-healthcheck` が起動していない (`docker compose up -d alb-healthcheck`)、または選んだサービスが `targets.json` のターゲットに無い |

詳細は [docs/ALB-HEALTHCHECK.md](docs/ALB-HEALTHCHECK.md) を参照。

### ECS Exec 関連 (ecs-exec / aws ecs execute-command)

| 症状 | 原因と対処 |
|---|---|
| `ClusterNotFoundException: Cluster not found.` | `--cluster` の指定漏れ / 誤り。省略すると実物と同じく `default` クラスターを探しに行く。`ecs-exec tasks` で正しいクラスター名を確認する |
| `InvalidParameterException: ... execute command was not enabled ...` | `enableExecuteCommand` が false。`aws ecs update-service --cluster ... --service ... --enable-execute-command` で戻す。**実 AWS ではこの変更後にタスクの置き換え (`--force-new-deployment`) が要る**点も注意 |
| `TargetNotConnectedException` | 接続先コンテナが動いていない。`ecs-exec doctor` の `ExecuteCommandAgent:` 行と `docker compose ps` を見る |
| `The container does not exist in the task.` | `--container` に compose のサービス名を書いている。実 AWS で通るのはタスク定義のコンテナ名 (`app-front` / `app-back`) |
| `Cannot connect to the Docker daemon` (doctor が NG) | docker ソケットが渡っていない。既定は `/var/run/docker.sock`。rootless Docker などパスが違う場合は `.env` の `DOCKER_SOCKET` で指定する |
| `--command "... \| grep ..."` が動かない | ECS Exec は `--command` をシェルに渡さない (実物と同じ)。`--command "sh -c '... \| grep ...'"` と書く |
| `ecs-exec put` が `Permission denied` | front/back は jboss (UID 185) で動くため書けない場所がある。実 ECS Exec も同じ制約。テスト目的なら `--user root` (偽装限定) |
| `ecs-exec put` が遅い | 1 チャンク = 1 セッションで送るため。`ECS_EXEC_PUT_CHUNK_CHARS` を増やすと減る (実物の引数長制限を模した既定値は 16384 文字) |

詳細は [docs/ECS-EXEC.md](docs/ECS-EXEC.md) を参照。

### cacert.crt の出力 (export) / build secret 関連

| 症状 | 原因と対処 |
|---|---|
| `compose/pki/export/` に何も出ない | `docker compose logs pki-init \| grep export:` を確認。`/export が無いため出力しません` なら bind mount が無い (compose.yaml の `${PKI_EXPORT_DIR:-./compose/pki/export}:/export`)。`./pki-export.sh` でコンテナから直接取り出すこともできる |
| `docker compose build` が `secret ... no such file or directory` | `compose/pki/export/cacert.crt` が未出力。先に `docker compose up -d pki-init`。このエラーは `-f compose.build-secret.yaml` を付けたときだけ起きる |
| ビルドログに `[build][cacert] ... スキップします` | secret が届いていない。`-f compose.build-secret.yaml` の指定、`docker build` なら `--secret id=cacert,src=...` の `id`、BuildKit の有効化 (`DOCKER_BUILDKIT=1`) を確認 |
| 出力物を `provided/` へ置いたら `cacert.key は cacert.crt の秘密鍵ではありません` で pki-init が落ちる | 配置先に古い `cacert.key` が残っている。消してから置き直す (`./pki-export.sh --to-provided` は自動で消す) |
| ビルド時に焼き込んだ証明書と実行時の中身が違う | `PKI_TRUST_DIR` に `*.crt` があると JBoss 側ストアは毎起動で作り直される。`docker compose logs frontend \| grep truststore` で `[build]` と `[jboss]` の両方を確認する |

### SSM / タスク起動関連

- `ResourceInitializationError: unable to pull secrets` → タスク実行ロールの
  `ssm:GetParameters` / `kms:Decrypt` とパラメータ名の一致を確認。
- SSM String は standard tier で 4KB 上限。Collector 設定が超える場合は
  advanced tier (8KB) にする (`register-parameters.sh` は Intelligent-Tiering 指定済みで自動昇格)。
- パラメータを更新しても反映されない → secrets はタスク起動時にのみ解決される。
  `--force-new-deployment` で新タスクを起動する。
- `CW_CONFIG_CONTENT_MID` を足したのに設定が効かない → エージェントが自動でロードするのは
  `CW_CONFIG_CONTENT` **だけ**。追加変数は taskdef の `entryPoint` で
  `/etc/cwagentconfig/NN-*.json` へ materialize する必要がある (2.7 節)。
  materialize 先のディレクトリはタスクレベル volume でマウントしておくこと
  (イメージに `mkdir(1)` が無い場合がある)。
- 追加設定を足したら `collect_list` が重複した → materialize 後に環境変数を `unset`
  していない可能性。エージェント側の `CW_CONFIG_CONTENT` 読み込み経路と二重になる。
- CW Agent 設定の JSON が壊れている / サイズ上限に触れる → `terraform plan` の時点で
  `jsondecode` と precondition が検出する (`terraform/`)。

### ローカル compose 固有

- `EAP_BASE_IMAGE` が pull できない → 社内レジストリへの `docker login` を確認。
- Jaeger UI にサービスが出ない → まず `./verify-local.sh` を実行。Collector の
  debug exporter ログにスパンが出ていれば Collector→Jaeger 間、出ていなければ
  アプリ→Collector 間の問題。
- ポート衝突 (3306/6379/8080 等) → ホスト側で既存のプロセスが使用していないか確認し、
  compose.yaml の `ports` の左側 (ホスト側) だけ変更する。
- cwagent から PutLogEvents が飛ばない → `./verify-local.sh` の 13/14 を見る。
  cwagent は entrypoint ラッパー (`compose/cwagent/verify-mount.sh`) が起動時と
  起動後に自己診断を出すので、`docker compose logs cwagent | grep cwagent-verify` で
  「マウント成立 / 設定 file_path の glob 一致件数 / open(2) 可否 / tail state の有無」を
  確認する。CloudWatch Agent のイメージはシェル操作での確認が難しいため、
  `docker compose exec` ではなくこのログを一次情報にする。
  - `マウントポイントではない` → compose.yaml の `cwagent.volumes` を確認
  - `glob に一致するファイルが 0 件` → アプリの出力パスと `cwagent-config.json` の
    `file_path` の食い違い
  - `読み取り不可 (open 失敗)` → 偽装 EFS の 6301:6302 権限と `group_add` を確認
- cwagent が `unable to get http response from http://169.254.170.2/v2/metadata` を出す
  → **`ecs-metadata-mock` が居るせいではなく、cwagent がそれを参照していないのが原因。**
  CloudWatch Agent は起動時に `ECS_CONTAINER_METADATA_URI_V4` → `ECS_CONTAINER_METADATA_URI`
  の順で見て、どちらも無いとソース埋め込みの v2 エンドポイント (`169.254.170.2` =
  ECS エージェントが用意するリンクローカルアドレス) へ直接アクセスする。compose の
  bridge ネットワークには存在しないため 1 秒 × 3 回リトライして「ECS ではない」と誤判定する。
  実 ECS はタスク内の**全コンテナ**へこの変数を注入するので、ローカルでも
  front/back/adot-collector と同様に `cwagent` / `cwagent-ssm` へ与えてそろえてある。
  判定は `./verify-local.sh` の 13-3。詳細は [README.md](README.md#efs--cloudwatch-logs-転送の偽装)。
- SSM 注入方式 (`cwagent-ssm`) の確認は `./verify-cwagent-ssm.sh`。
  `docker compose --profile ssm-config up -d cwagent-ssm` で起動してから実行する
  (`profiles` でゲートしているため通常の `up` では起動しない)。
  `[cwagent-ssm]` 行が materialize の結果、`[cwagent-verify]` 行が従来どおりの
  マウント/権限診断。マージが成立したかは検証スクリプトの 4 (実効設定に両系統の
  `log_group_name` が載っているか) で判定する。詳細は
  [docs/CWAGENT-SSM-CONFIG.md](docs/CWAGENT-SSM-CONFIG.md)。
