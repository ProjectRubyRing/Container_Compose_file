# 非同期処理チェーン (SQS → Lambda → ALB → app-back) ローカル検証ガイド

app-front / app-back から **非同期に** 処理を投げ、SQS・Lambda・ALB を経由して
最終的に app-back の Java サーブレットが POST を受け取るまでの一連の流れを、
**AWS に一切接続せず** ローカルの compose だけで再現・検証するための構成と手順です。

このドキュメントだけを読めば、

- Lambda で使う Python 関数の **実装方法・配置方法**
- SQS キューの **設定方法**
- ALB の **設定方法**

がすべて分かるように、極力ていねいに説明します。

---

## 0. 全体像

### 処理の流れ

```
┌──────────────┐   ①SendMessage        ┌──────────────────────┐
│ app-front /  │ ────────────────────▶ │  sqs (ElasticMQ)     │
│ app-back     │   非同期でキューに積む  │  app-async-queue     │
└──────────────┘                        └──────────┬───────────┘
                                                    │ ②ReceiveMessage
                                                    │  (ロングポーリング)
                                          ┌─────────▼───────────┐
                                          │ lambda-esm          │  ← イベントソース
                                          │ (poller.py)         │     マッピングの代替
                                          └─────────┬───────────┘
                                                    │ ③HTTP invoke
                                                    │  {"Records":[...]}
                                          ┌─────────▼───────────┐
                                          │ lambda (RIE)        │  ← Lambda ランタイム
                                          │ handler.py          │     の代替
                                          └─────────┬───────────┘
                                                    │ ④HTTP POST
                                                    │  /async/receive
                                          ┌─────────▼───────────┐
                                          │ alb (nginx)         │  ← ALB の代替
                                          │ /async/* → app-back │     (L7 ルーティング)
                                          └─────────┬───────────┘
                                                    │ ⑤proxy_pass
                                          ┌─────────▼───────────┐
                                          │ app-back:8180       │
                                          │ AsyncReceiverServlet│  ← Java サーブレット
                                          │ /async/receive      │     (async-receiver.war)
                                          └─────────┬───────────┘
                                                    │ ⑥DeleteMessage
                                                    ▼ (成功時のみ poller が削除)
                                              処理完了
```

### 実 AWS 構成との対応表

| ローカル (compose) | 実 AWS | 役割 |
|---|---|---|
| `sqs` (ElasticMQ) | Amazon SQS | キュー本体 (`app-async-queue` / DLQ) |
| `lambda-esm` (poller.py) | Lambda **イベントソースマッピング** | SQS をポーリングし Lambda を起動 |
| `lambda` (RIE + handler.py) | AWS Lambda 関数 | SQS イベントを処理 |
| `alb` (nginx) | Application Load Balancer | L7 パスルーティング |
| `app-back` の `/async/receive` | ECS 上の app-back | Java サーブレットが POST を受信 |

> **なぜ `lambda-esm` が必要か？**
> 実 AWS では「SQS にメッセージが入ると Lambda が自動起動する」ように見えますが、
> 実体は Lambda サービス内部の **イベントソースマッピング** が SQS を裏でロング
> ポーリングして Lambda を呼んでいます。ローカルの Lambda ランタイム (RIE) には
> この自動ポーリング機能が無いため、`lambda-esm` (poller.py) がその役割を肩代わり
> します。これが「SQS 消費 → Lambda 関数呼び出し」の要です。

---

## 1. クイックスタート

```bash
cp .env.example .env      # EAP_BASE_IMAGE を設定 (app-back のビルドに必要)
docker compose up -d --build

# 一連の非同期チェーンをまとめて検証
./verify-async.sh
```

主要ポート (ホスト側):

| URL | 用途 |
|---|---|
| http://localhost:9324 | SQS API (`aws --endpoint-url http://localhost:9324 ...`) |
| http://localhost:9325 | ElasticMQ 統計/管理 UI |
| http://localhost:9000 | 非同期 Lambda を直接 invoke (`/2015-03-31/functions/function/invocations`) |
| http://localhost:9001 | メンテナンス Lambda を直接 invoke |
| http://localhost:9080 | ALB (nginx)。`/async/receive`, `/maintenance`, `/healthz` |
| http://localhost:9081 | alb-lambda-adapter 直接 (ALB→Lambda 変換の確認用) |
| http://localhost:8180 | app-back 直接 (`/async/receive`) |

---

## 2. SQS キューの設定方法 (`sqs` / ElasticMQ)

### 2-1. 使用イメージと役割

- イメージ: `softwaremill/elasticmq-native:1.6.11`
- **ElasticMQ** は Amazon SQS 互換の HTTP API を提供する軽量サーバです。
  AWS SDK や `awscli` の `--endpoint-url` をこのコンテナに向けるだけで、
  `SendMessage` / `ReceiveMessage` / `DeleteMessage` などが実 SQS とほぼ同じに使えます。

### 2-2. 設定ファイル `compose/sqs/elasticmq.conf`

HOCON 形式です。特に重要なポイントは 2 つ。

**① `node-address` は compose のサービス名 `sqs` にする**

```hocon
node-address {
    protocol = http
    host = sqs        # ← ここが最重要
    port = 9324
    context-path = ""
}
generate-node-address = false
```

`GetQueueUrl` が返す **QueueUrl のホスト名** がこの `host` になります。
`lambda-esm` はその QueueUrl をそのまま `ReceiveMessage` / `DeleteMessage` に使うため、
compose ネットワーク内で名前解決できる **サービス名 `sqs`** にしておく必要があります。
（`localhost` のままだと lambda-esm が自分自身を指してしまい通信できません。）

**② キューと DLQ (デッドレターキュー) を起動時に自動作成する**

```hocon
queues {
    app-async-dlq { }                     # 失敗メッセージの退避先

    app-async-queue {
        defaultVisibilityTimeout = 30 seconds   # 取得後この間は他から見えない
        receiveMessageWait = 0 seconds
        deadLettersQueue {
            name = "app-async-dlq"
            maxReceiveCount = 3           # 3回受信されても消えなければ DLQ 行き
        }
    }
}
```

| 設定 | 意味 | 実 SQS での対応 |
|---|---|---|
| `defaultVisibilityTimeout` | 受信後にメッセージが不可視になる時間。処理〜削除をこの間に終える | Visibility Timeout |
| `deadLettersQueue` + `maxReceiveCount` | N 回処理に失敗したら DLQ へ移動 | RedrivePolicy |

### 2-3. メッセージの積み方 (プロデューサ)

実 AWS では app-front / app-back が **AWS SDK (SendMessage)** でキューに積みます。
compose 環境では endpoint を `sqs` に向けるだけです。app-front / app-back には
`ASYNC_SQS_ENDPOINT=http://sqs:9324` と `ASYNC_QUEUE_NAME=app-async-queue` を
環境変数で渡してあります。

ローカルで手動投入する例 (`awscli` を使う場合):

```bash
aws --endpoint-url http://localhost:9324 --region ap-northeast-1 \
    sqs send-message \
    --queue-url http://localhost:9324/000000000000/app-async-queue \
    --message-body '{"orderId":"A-1001","action":"createReport"}'
```

`awscli` が無くても、`verify-async.sh` は `sqs` コンテナ内から投入するので追加インストール不要です。

### 2-4. キューの状態確認

```bash
# キュー一覧
aws --endpoint-url http://localhost:9324 sqs list-queues

# たまっているメッセージ数など
aws --endpoint-url http://localhost:9324 sqs get-queue-attributes \
    --queue-url http://localhost:9324/000000000000/app-async-queue \
    --attribute-names All

# 統計 UI
open http://localhost:9325
```

---

## 3. Lambda で使う Python 関数の実装方法・配置方法

### 3-1. 使用イメージと仕組み (RIE)

- イメージ: `public.ecr.aws/lambda/python:3.12` (AWS 公式 Lambda ベースイメージ)
- このイメージには **Runtime Interface Emulator (RIE)** が同梱されており、
  ローカルで起動すると **8080 番ポート** に invoke エンドポイントが立ち上がります:

  ```
  POST http://lambda:8080/2015-03-31/functions/function/invocations
  ```

  ここへイベント JSON を POST すると、あたかも実 Lambda が呼ばれたかのように
  ハンドラ関数が実行されます。

### 3-2. 関数の配置方法

```
compose/lambda/app/handler.py     ← ホスト側の関数コード
        │  (compose の volumes でマウント)
        ▼
コンテナ内 /var/task/handler.py    ← Lambda が探す既定ディレクトリ
```

compose 側の指定:

```yaml
lambda:
  image: public.ecr.aws/lambda/python:3.12
  command: ["handler.lambda_handler"]        # "<ファイル名>.<関数名>"
  volumes:
    - ./compose/lambda/app:/var/task:ro       # ここに handler.py を置く
```

- **ハンドラの指定**は `command`(= イメージの CMD) に `handler.lambda_handler` と書きます。
  これは「`handler.py` の `lambda_handler` 関数を呼ぶ」という意味です。
  関数名やファイル名を変えたら、この `command` も合わせて変更します。
- コードを増やす場合は `compose/lambda/app/` 配下にファイルを追加すれば
  `/var/task` から `import` できます。

### 3-3. 依存ライブラリを追加したい場合

今回の `handler.py` は **標準ライブラリ (urllib) のみ** で書いているため、
`pip install` は不要でボリュームマウントのまま動きます。

外部ライブラリ (例: `requests`) を使いたくなったら、`lambda` サービスを
専用 Dockerfile 方式に切り替えます:

```dockerfile
# compose/lambda/Dockerfile
FROM public.ecr.aws/lambda/python:3.12
COPY app/requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install -r ${LAMBDA_TASK_ROOT}/requirements.txt
COPY app/ ${LAMBDA_TASK_ROOT}/
CMD ["handler.lambda_handler"]
```

```yaml
# compose.yaml (lambda サービス)
lambda:
  build:
    context: ./compose/lambda
  # image: と volumes: と command: は削除
```

### 3-4. 関数の中身 (`compose/lambda/app/handler.py`)

要点だけ抜粋します (全文はファイル参照)。

```python
def lambda_handler(event, context):
    records = event.get("Records", [])       # SQS イベント {"Records":[...]}
    batch_item_failures = []
    for record in records:
        message_id = record.get("messageId", "")
        body = record.get("body", "")
        try:
            status, _ = _post_to_back(body, message_id)   # ALB 経由で app-back へ POST
            if not (200 <= status < 300):
                batch_item_failures.append({"itemIdentifier": message_id})
        except Exception:
            batch_item_failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": batch_item_failures}
```

**戻り値の `batchItemFailures`** は実 SQS の
**部分バッチ応答 (ReportBatchItemFailures)** と同じ形式です。
ここに載せた `messageId` は `lambda-esm` が削除せず、可視性タイムアウト経過後に
再処理されます (3 回失敗で DLQ 行き)。成功したメッセージだけが削除されます。

POST 先は環境変数で制御します:

```yaml
environment:
  ALB_ENDPOINT: http://alb:80      # ALB(nginx)
  BACK_PATH: /async/receive        # ALB のルール /async/* と一致させる
```

### 3-5. Lambda を単体で直接テストする

`lambda-esm` を介さず、ホストから RIE を直接叩けます:

```bash
curl -s -XPOST \
  "http://localhost:9000/2015-03-31/functions/function/invocations" \
  -d '{"Records":[{"messageId":"m-1","body":"{\"hello\":\"world\"}"}]}'
# → {"batchItemFailures": []}  (成功。app-back に POST が届く)
```

---

## 4. イベントソースマッピングの代替 (`lambda-esm` / poller.py)

`compose/lambda-esm/poller.py` が「SQS をポーリングして Lambda を呼ぶ」役割です。

処理ループ:

1. `receive_message`(WaitTimeSeconds=20) で **ロングポーリング**
2. 受信メッセージを **実 SQS イベントと同じ JSON** に整形
   (`messageId` / `receiptHandle` / `body` / `eventSource=aws:sqs` など)
3. `lambda` の RIE を **HTTP invoke**
4. 戻り値 `batchItemFailures` に **含まれないメッセージだけ** `delete_message`
   (失敗分は放置 → 可視性タイムアウト後に再配信 → 3 回で DLQ)

依存は `boto3` (SQS 用) のみで、`compose/lambda-esm/Dockerfile` でインストールしています。

主な環境変数:

| 変数 | 既定値 | 意味 |
|---|---|---|
| `SQS_ENDPOINT` | `http://sqs:9324` | ElasticMQ の endpoint |
| `QUEUE_NAME` | `app-async-queue` | ポーリング対象キュー |
| `LAMBDA_INVOKE_URL` | `http://lambda:8080/.../invocations` | Lambda RIE の invoke URL |
| `BATCH_SIZE` | `10` | 1 回の取得件数 (最大 10) |
| `WAIT_TIME_SECONDS` | `20` | ロングポーリング秒数 (最大 20) |

---

## 5. ALB の設定方法 (`alb` / nginx)

### 5-1. 使用イメージと役割

- イメージ: `nginx:1.27-alpine`
- **ALB (Application Load Balancer)** の L7 ルーティングを nginx で模擬します。

  | nginx | ALB の概念 |
  |---|---|
  | `upstream app_back { server app-back:8180; }` | ターゲットグループ (app-back) |
  | `listen 80;` | リスナー (HTTP :80) |
  | `location /async/ { proxy_pass ... }` | リスナールール「パスが `/async/*` なら転送」 |
  | `proxy_set_header X-Forwarded-*` | ALB が付与するヘッダ |

### 5-2. 設定ファイル `compose/alb/nginx.conf`

```nginx
upstream app_back {
    server app-back:8180;          # app-back は port-offset=100 で 8180
}

server {
    listen 80;

    location = /healthz {           # ALB 自体の死活確認
        return 200 "alb-ok\n";
    }

    location /async/ {              # ← リスナールール: /async/* を app-back へ
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://app_back;
    }
}
```

- Lambda は `http://alb:80/async/receive` に POST します。
- nginx はパスを保持したまま `app-back:8180/async/receive` へ転送します。
- **パスの一致が肝**です。3 者を必ず揃えます:
  - Lambda の `BACK_PATH` = `/async/receive`
  - nginx の `location /async/`
  - サーブレットの URL = コンテキストルート `/async` + マッピング `/receive`

### 5-3. ALB 経由の疎通確認

```bash
curl http://localhost:9080/healthz
# alb-ok

curl -XPOST http://localhost:9080/async/receive \
     -H 'Content-Type: application/json' \
     -d '{"probe":"via-alb"}'
# {"status":"received", ...}
```

---

## 6. app-back 側 Java サーブレット (`async-receiver.war`)

### 6-1. 配置と URL の確定

| 項目 | 値 | 決めている場所 |
|---|---|---|
| サーブレットマッピング | `/receive` | `@WebServlet(urlPatterns={"/receive"})` |
| コンテキストルート | `/async` | `WEB-INF/jboss-web.xml` の `<context-root>` |
| 最終 URL | **`/async/receive`** | 上記の組み合わせ |

WAR 名 (`async-receiver.war`) に依存せず URL を固定するため、
`jboss-web.xml` でコンテキストルートを明示しています。

### 6-2. ビルドと配備 (自動)

`docker/back/servlet/` が Maven プロジェクトです。**ローカルに Maven は不要** で、
`back/Dockerfile` のビルドステージ (maven イメージ) が WAR をビルドし、
最終イメージの `deployments/` へコピーします:

```
docker/back/servlet/           ← Maven プロジェクト (pom.xml / src)
        │ docker compose build (back/Dockerfile の warbuild ステージ)
        ▼
async-receiver.war             ← ${JBOSS_HOME}/standalone/deployments/ に配備
```

`jakarta.servlet-api` は EAP が提供するため `scope=provided` で WAR には同梱しません。

### 6-3. 受信時の挙動

- POST ボディを **標準出力** (`docker logs app-back`) に記録
- 書き込み可能なら **偽装 EFS** `/mnt/logs/app-back-async.log` にも追記
  (cwagent が拾い、CloudWatch Logs モックへ転送されるのも確認できる)
- `200 OK` を JSON で返す (`{"status":"received", ...}`)

---

## 7. エンドツーエンド検証手順

`./verify-async.sh` が下記を自動実行します。手動で追う場合は以下。

```bash
# 1) キューにメッセージを投入 (プロデューサ = app-front/app-back 相当)
docker compose exec sqs \
  sh -c 'wget -qO- "http://localhost:9324/?Action=SendMessage&QueueName=app-async-queue&MessageBody=%7B%22orderId%22%3A%22A-1001%22%7D"' \
  >/dev/null 2>&1 || \
aws --endpoint-url http://localhost:9324 --region ap-northeast-1 sqs send-message \
  --queue-url http://localhost:9324/000000000000/app-async-queue \
  --message-body '{"orderId":"A-1001","action":"createReport"}'

# 2) poller が Lambda を起動し、Lambda が ALB 経由で app-back を POST 呼び出し
docker compose logs --tail 20 lambda-esm   # "received 1 message(s); invoking lambda"
docker compose logs --tail 20 lambda       # {"handler":"lambda_handler","received":1,...}
docker compose logs --tail 20 alb          # "POST /async/receive" status=200
docker compose logs --tail 20 app-back | grep async-receiver
#   ... [app-back][async-receiver] source=lambda-local messageId=... body={"orderId":"A-1001"...}

# 3) 正常処理されたメッセージはキューから消える
aws --endpoint-url http://localhost:9324 sqs get-queue-attributes \
  --queue-url http://localhost:9324/000000000000/app-async-queue \
  --attribute-names ApproximateNumberOfMessages
```

---

## 7.5 メンテナンス画面 Lambda と ALB リスナールール切り替え

ALB のリスナールールから **メンテナンス画面用 Lambda** を呼び出し、
メンテナンス画面 (HTML) とメンテナンス用ステータスコード (既定 503) を返す構成です。
Python コードも ALB のルール切り替えも、どちらも **差し替え可能** にしています。

### 7.5-1. 構成

```
             ┌──────────── ALB (nginx) ─────────────┐
  クライアント │  リスナールール (include rules/*.conf) │
    │  HTTP   │                                       │
    ▼         │  /maintenance*  ─────────────┐        │
  :9080 ──────┤  (常時有効: 00-...conf)       │        │
              │                              │        │
              │  /  , /async/  ── 10-routes.conf ──┐   │
              │   (★切り替え可能★)            │   │   │
              └──────────────────────────────┼───┼───┘
                     通常=app-back            │   │全面メンテ=maint
                                              ▼   ▼
                                   app-back   alb-lambda-adapter
                                   :8180        │ (HTTP↔Lambda 変換)
                                                ▼
                                     maintenance-lambda (RIE)
                                     maintenance.py → 503 + 画面HTML
```

| コンテナ | 実 AWS | 役割 |
|---|---|---|
| `maintenance-lambda` (RIE + `maintenance.py`) | Lambda 関数 | メンテナンス画面 HTML とステータスコードを返す |
| `alb-lambda-adapter` (`adapter.py`) | ALB の **Lambda ターゲット統合** | HTTP ⇄ ELB Lambda イベントの変換 |

> **なぜ `alb-lambda-adapter` が必要か？**
> 実 ALB は Lambda をターゲットにすると、HTTP を ELB イベント JSON に変換して
> invoke し、Lambda の応答 (`statusCode`/`headers`/`body`) を HTTP に戻す処理を
> ALB 自身が行います。ローカルの Lambda ランタイム (RIE) にはこの変換が無いため、
> `alb-lambda-adapter` が nginx と maintenance-lambda の間でその変換を肩代わりします。

### 7.5-2. メンテナンス用 Python の差し替え方法

- 実体: `compose/maintenance-lambda/app/maintenance.py`
- コンテナ内 `/var/task/maintenance.py` に **ボリュームマウント** されている。
- 画面 HTML は `_render_html()` を編集、ステータスコードは環境変数
  `MAINTENANCE_STATUS_CODE` (compose.yaml) で変更する。
- 反映は再ビルド不要:

  ```bash
  # maintenance.py を編集後
  docker compose restart maintenance-lambda
  ```

- 応答形式は ALB の Lambda ターゲットと同じ:

  ```python
  return {
      "statusCode": 503,
      "statusDescription": "503 Service Unavailable",
      "isBase64Encoded": False,
      "headers": {"Content-Type": "text/html; charset=utf-8", "Retry-After": "300"},
      "body": "<!doctype html>...",   # メンテナンス画面
  }
  ```

### 7.5-3. ALB リスナールールの差し替え・切り替え方法

リスナールールは **`nginx.conf` 本体から分離** し、`compose/alb/rules/*.conf` を
`include` する構成です (`nginx.conf` は編集不要)。

```
compose/alb/rules/
  00-maintenance-path.conf     # 常時有効: /maintenance* → メンテナンス Lambda
  10-routes.conf               # ★切り替え対象★ 通常 or 全面メンテ (現在の実体)
  variants/
    10-routes.normal.conf      # 切り替えソース: 通常 (すべて app-back)
    10-routes.maintenance.conf # 切り替えソース: 全面メンテ (すべて maint Lambda)
```

- `rules/*.conf` はディレクトリごと `/etc/nginx/rules` にマウントされ、
  nginx が `include /etc/nginx/rules/*.conf` で読み込む
  (`variants/` はサブディレクトリなので `*.conf` に一致せず読み込まれない = 差し替え用の置き場)。

**全面メンテナンス ON/OFF (付属スクリプト):**

```bash
./alb-maintenance.sh on      # 全経路をメンテナンス Lambda (503+画面) へ
./alb-maintenance.sh off     # 通常 (app-back) へ戻す
./alb-maintenance.sh status  # 現在の状態を表示
```

スクリプトは `variants/10-routes.<mode>.conf` を `10-routes.conf` へコピーし、
`nginx -s reload` する (コンテナ再起動不要)。

**ルール自体を書き換える** 場合は `compose/alb/rules/*.conf` を直接編集し:

```bash
docker compose exec alb nginx -t && docker compose exec alb nginx -s reload
```

> `/maintenance*` ルール (`00-maintenance-path.conf`) は ON/OFF と独立に常時有効。
> 全面メンテナンスにしなくても、いつでも画面プレビューできます:
> `curl http://localhost:9080/maintenance`

### 7.5-4. 動作確認

```bash
# ① メンテナンス画面プレビュー (常時ルール経由)。503 + HTML が返る
curl -i http://localhost:9080/maintenance

# ② Lambda を直接 invoke (RIE。ELB イベント形式)
curl -s -XPOST http://localhost:9001/2015-03-31/functions/function/invocations \
  -d '{"httpMethod":"GET","path":"/maintenance","headers":{},"body":""}'

# ③ アダプタ経由 (nginx を介さず HTTP で。ALB→Lambda 変換の確認)
curl -i http://localhost:9081/anything

# ④ 全面メンテナンスに切り替え → 通常経路 (/) も 503 になる
./alb-maintenance.sh on
curl -i http://localhost:9080/           # 503 + メンテナンス画面
curl -i http://localhost:9080/async/receive -X POST -d '{}'   # これも 503
./alb-maintenance.sh off                 # 通常に戻す
```

---

## 8. トラブルシューティング

| 症状 | 原因・確認ポイント |
|---|---|
| `lambda-esm` が `waiting for queue` を繰り返す | `sqs` 未起動、または `elasticmq.conf` の `node-address.host` が `sqs` になっていない |
| メッセージが消えず何度も再処理される | Lambda が非 2xx を返している (app-back or ALB 到達不可)。`docker logs lambda` を確認 |
| メッセージが DLQ (`app-async-dlq`) に溜まる | 3 回失敗した。ALB→app-back の経路とサーブレット配備を確認 |
| ALB で 404 | パス不一致。`BACK_PATH` / `location /async/` / `@WebServlet`+`context-root` を突き合わせる |
| app-back に POST が届かない | `alb` の `upstream` が `app-back:8180` (port-offset 込み) か確認 |
| Lambda 直接 invoke が 502 | `handler.py` の例外。`docker logs lambda` にスタックトレースが出る |
| `/maintenance` が 502 | `alb-lambda-adapter` か `maintenance-lambda` が未起動。`docker logs alb-lambda-adapter` を確認 |
| メンテナンス画面が崩れる/更新されない | `maintenance.py` 編集後に `docker compose restart maintenance-lambda` を実行したか |
| `alb-maintenance.sh on` が効かない | `docker compose exec alb nginx -s reload` が成功したか (alb 起動中か) を確認 |

DLQ の中身を確認:

```bash
aws --endpoint-url http://localhost:9324 sqs receive-message \
  --queue-url http://localhost:9324/000000000000/app-async-dlq \
  --max-number-of-messages 10
```

---

## 9. 変更・拡張のヒント

- **キューを増やす**: `elasticmq.conf` の `queues { ... }` に追記し、`lambda-esm` を複製して
  `QUEUE_NAME` を変える (実 AWS の「キューごとにイベントソースマッピング」に相当)。
- **Lambda の処理内容を変える**: `compose/lambda/app/handler.py` を編集して
  `docker compose restart lambda` (ボリュームマウントなので再ビルド不要)。
- **ALB のルーティングを増やす**: `nginx.conf` に `location` を追加。
- **可視性タイムアウト/リトライ回数の調整**: `elasticmq.conf` の
  `defaultVisibilityTimeout` / `maxReceiveCount`。
