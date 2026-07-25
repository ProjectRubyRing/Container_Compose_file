# 自己署名証明書による HTTPS 検証 (secure-api / JVM トラストストア / ALB)

自己署名した証明書でのみ HTTPS を受け付ける REST API サーバを追加し、
**app-front / app-back の JVM トラストストアへ CA (または自己署名証明書そのもの) を
取り込むことで、アプリコードを無改変のまま REST API を呼び出せる**ことを検証する構成。
ALB (HTTPS リスナー) を経由した場合も同様に検証できる。

---

## 1. 全体像

```
                          ┌──────────────────────────────────────────┐
                          │ pki-init (openssl)                        │
                          │  ルート CA(自己署名) → 中間 CA → 各サーバ証明書│
                          └──────────────┬───────────────────────────┘
                                         │ named volume: pki (読み取り専用で共有)
        ┌────────────────────────────────┼─────────────────────────────┐
        │                                │                             │
        ▼                                ▼                             ▼
┌───────────────┐   (C) 直接 HTTPS  ┌──────────────┐          ┌────────────────┐
│  app-front    │ ────────────────▶ │  secure-api  │          │  alb (nginx)   │
│  app-back     │                   │  WireMock    │◀─────────│  HTTPS :443    │
│  (JBoss EAP)  │ ─────(E) ALB 経由─▶│  HTTPS のみ  │  (B) 再暗号化 (HTTPS)    │
│               │                   │  :8443       │          │  HTTP  :80     │
│ entrypoint が │                   └──────────────┘          └────────────────┘
│ keytool で CA │                                                     ▲
│ をトラストストア│                                                     │
│ へ取り込む     │                                                     │
└───────────────┘                                                     │
        ▲                                                             │
        └──────────────── tls-verifier (curl/openssl/jq) ─────────────┘
                          上記すべてを機械的に検証する
```

| サービス | 役割 | ポート (ホスト:コンテナ) |
|---|---|---|
| `pki-init` | 自己署名 PKI 一式を発行し named volume `pki` へ配置 | なし |
| `secure-api` | **HTTPS でのみ**待ち受ける REST API (WireMock) | `8543:8443` |
| `alb` | ALB 代替。HTTPS リスナーを追加 (証明書適用) | `9080:80` / **`9443:443`** |
| `app-front` / `app-back` | JVM トラストストアへ CA を取り込み、`tls-probe` から HTTPS 呼び出し | `8080` / `8180` |
| `tls-verifier` | 検証専用コンテナ (`profiles: verify`) | なし |

---

## 2. 発行する証明書 (pki-init)

`compose/pki/gen-certs.sh` が起動時に一度だけ発行する (冪等。2 回目以降は再利用)。

```
/pki/
  ca/root-ca.crt|key              ルート CA (自己署名, CA:TRUE pathlen:1)
  ca/intermediate-ca.crt|key      中間 CA (ルート CA が署名, CA:TRUE pathlen:0)
  ca/ca-chain.crt                 中間 + ルート (クライアント検証用 CA バンドル)
  secure-api/server.crt|key       secure-api のサーバ証明書 (中間 CA 発行)
  secure-api/fullchain.crt        リーフ + 中間 CA
  secure-api/server.p12           WireMock(Jetty) 用 PKCS#12 キーストア
  alb/ca-issued/server.crt|key    ALB 用 ★パターンA: 中間 CA 発行
  alb/selfsigned/server.crt|key   ALB 用 ★パターンB: 自己署名リーフ
  trust/10-local-test-root-ca.crt         ┐
  trust/20-local-test-intermediate-ca.crt │ front/back のトラストストアへ入れる
  trust/30-alb-selfsigned.crt             ┘ (ファイル名がそのまま keytool の alias)
```

SAN (subjectAltName) はコンテナ名で名前解決できるように設定している。

| 証明書 | CN | SAN |
|---|---|---|
| secure-api | `secure-api` | `DNS:secure-api, DNS:secure-api.local, DNS:localhost, IP:127.0.0.1` |
| ALB (両パターン) | `alb.example.internal` | `DNS:alb, DNS:alb.local, DNS:alb.example.internal, DNS:localhost, IP:127.0.0.1` |

### 意図的に 2 つの信頼形態を用意している

要件の「その自己証明書、もしくは中間 CA 証明書をインポート」の**両方**を検証できるようにするため。

| | パターン A: CA 発行 | パターン B: 自己署名 |
|---|---|---|
| 使う場所 | `secure-api` / ALB(`ca-issued`) | ALB(`selfsigned`) |
| トラストストアに入れるもの | **中間 CA + ルート CA 証明書** | **サーバ証明書そのもの** |
| サーバ証明書を再発行したとき | CA が同じならトラストストア更新**不要** | 毎回トラストストアの更新が**必要** |
| 実 AWS での相当 | ACM (Private CA 発行 / インポート) | 自己署名証明書を ACM にインポート |

---

## 3. JVM トラストストアへの取り込み (front / back)

`docker/front/entrypoint.sh` と `docker/back/entrypoint.sh` の
`import_trusted_certs()` が起動時に実行する。**アプリコードは無改変**。

```
1. /mnt/pki/trust/*.crt があるか確認 (無ければスキップして通常起動)
2. JDK 同梱の cacerts を探して /tmp/pki/cacerts へコピー
     ${JAVA_HOME}/lib/security/cacerts → /etc/pki/java/cacerts → java の実体から逆引き
3. keytool -importcert で *.crt を追加 (alias = ファイル名から拡張子を除いたもの)
4. JAVA_TOOL_OPTIONS に -Djavax.net.ssl.trustStore=/tmp/pki/cacerts を追加
```

### なぜコピーしてから使うのか

- コンテナは `jboss` (UID 185) で動くため、root 所有の
  `${JAVA_HOME}/lib/security/cacerts` を直接書き換えられない。
- **コピー元は JDK 同梱の cacerts なので、パブリック CA の信頼はそのまま残る。**
  自己署名 CA を「追加」するだけで既存の信頼関係を壊さない。
- 毎起動でコピーし直すため alias の重複エラーが起きず、証明書を作り直しても
  コンテナを再起動するだけで最新が反映される。

### なぜ `JAVA_TOOL_OPTIONS` か

`JAVA_OPTS_APPEND` (JBoss 標準) でも渡せるが、`JAVA_TOOL_OPTIONS` は JVM が必ず
解釈するため、`jboss-cli` など補助 JVM からも同じトラストストアが使われる。
既存の ADOT Java Agent (`-javaagent`) と同じ変数に追記している。

### 環境変数

| 変数 | 既定値 | 説明 |
|---|---|---|
| `PKI_TRUST_DIR` | `/mnt/pki/trust` | 取り込む `*.crt` の置き場 |
| `JVM_TRUSTSTORE_FILE` | `/tmp/pki/cacerts` | 生成するトラストストアの場所 |
| `JVM_TRUSTSTORE_PASSWORD` | `changeit` | コピー元 cacerts のパスワード (JDK 既定値) |
| `TRUSTSTORE_IMPORT_REQUIRED` | `false` | `true` にすると取り込み失敗で起動を中止する |

`trustStoreType` は**あえて指定していない** (JKS / PKCS12 は JDK が自動判別するため。
明示するとコピー元の形式が変わったときに読めなくなる)。

---

## 4. HTTPS を要求する REST API (secure-api)

WireMock を `--disable-http` 付きで起動し、**平文 HTTP のポートを一切 listen しない**。
サーバ証明書は pki-init が発行した PKCS#12 をそのまま渡す。

```yaml
command:
  - --https-port=8443
  - --https-keystore=/pki/secure-api/server.p12
  - --keystore-type=PKCS12
  - --keystore-password=changeit
  - --key-manager-password=changeit
  - --disable-http           # ← これにより「HTTPS を要求する」サーバになる
```

提供する REST API (スタブは `compose/secure-api/mappings/`):

| メソッド | パス | 応答 |
|---|---|---|
| GET | `/api/v1/ping` | 200 `{"status":"ok",...}` |
| GET | `/api/v1/items/{id}` | 200 (商品 JSON) |
| POST | `/api/v1/orders` | 201 + `Location` ヘッダ |
| GET | `/health` | 200 (ALB ヘルスチェック相当) |

---

## 5. ALB (HTTPS リスナー)

`compose/alb/nginx.conf` に `listen 443 ssl` の server ブロックを追加した。

```
compose/alb/
  nginx.conf                                    # 80 と 443 の 2 リスナー
  rules/*.conf                                  # HTTP リスナーのルール (既存)
  rules-tls/10-secure-routes.conf               # HTTPS リスナーのルール ★差し替え可能
  tls/10-server-cert.conf                       # 適用する証明書       ★差し替え可能
  tls/variants/10-server-cert.selfsigned.conf   #   切り替え元 (自己署名)
  tls/variants/10-server-cert.ca-issued.conf    #   切り替え元 (中間 CA 発行)
```

HTTPS リスナーのルーティング (`rules-tls/10-secure-routes.conf`):

| パス | 転送先 | 実 ALB での相当 |
|---|---|---|
| `/secure/*` | `https://secure-api:8443/api/*` | ターゲットグループのプロトコル = **HTTPS** (再暗号化) |
| `/async/*`, `/` | `http://app-back:8180` | ターゲットグループのプロトコル = HTTP (ALB で TLS 終端) |

`/secure/*` では `proxy_ssl_verify on` + `proxy_ssl_trusted_certificate /pki/ca/ca-chain.crt`
でターゲット証明書も検証している (実 ALB はターゲット証明書を検証しないため、
挙動を合わせたい場合は `proxy_ssl_verify off` にする)。

### 証明書の切り替え

```bash
./alb-tls-cert.sh selfsigned   # 自己署名証明書を適用 (既定)
./alb-tls-cert.sh ca-issued    # 中間 CA 発行の証明書を適用
./alb-tls-cert.sh status       # 適用中の設定と、実際に提示される証明書を表示
```

証明書ファイルは volume に発行済みなので、**切り替えは nginx の reload だけで即時**。
どちらに切り替えても front/back のトラストストアは更新不要 (両方を信頼済み)。

### 自前の証明書を適用する

1. 証明書と鍵を alb コンテナから見えるパスへマウントする
   ```yaml
   # compose.yaml の alb サービス
   volumes:
     - ./mycerts:/etc/nginx/mycerts:ro
   ```
2. `compose/alb/tls/10-server-cert.conf` のパスを書き換える
   ```nginx
   ssl_certificate     /etc/nginx/mycerts/fullchain.pem;
   ssl_certificate_key /etc/nginx/mycerts/privkey.pem;
   ```
3. `docker compose exec alb nginx -s reload`
4. その証明書 (または発行元 CA) を `compose/pki/gen-certs.sh` が出力する
   `trust/` へ置くか、`PKI_TRUST_DIR` を自前のディレクトリへ向けて front/back を再起動

---

## 6. 検証方法

### 6-1. 一括検証

```bash
docker compose up -d --build
./verify-tls.sh              # コンテナ内 + ホストからの検証
./verify-tls.sh quick        # JVM 経路のみ (短時間)
./verify-tls.sh host         # ホストからの検証のみ
```

`docker compose run --rm tls-verifier` でも同じ検証が走る (FAIL 数が終了コード)。

検証項目:

| # | 内容 | 期待値 |
|---|---|---|
| 0 | PKI 一式が生成され、チェーンが検証できる | OK |
| 2 | `secure-api:8080` (平文 HTTP) が listen していない | 接続不可 |
| 3 | **CA を信頼しない**クライアントからの HTTPS | **失敗** (対照実験) |
| 4 | CA を信頼したクライアントからの REST 呼び出し | 200 / 201 |
| 5 | サーバが提示するチェーン (openssl s_client) | `Verify return code: 0 (ok)` |
| 6 | ALB(HTTPS) → secure-api(再暗号化) | 200 |
| 7 | front/back のトラストストアに証明書が入っている | 3 件 |
| 8 | **front/back の JVM から直接 HTTPS REST 呼び出し** | 200 |
| 9 | **front/back の JVM から ALB 経由で REST 呼び出し** | 200 |

項目 3 が「失敗」することが重要で、これにより
**「トラストストアへ取り込んだから通っている」**ことが証明される。

### 6-2. front / back の JVM から個別に確認する (tls-probe)

`docker/probe/` の `tls-probe.war` を front と back の両方に配備している。
JDK 標準の `java.net.http.HttpClient` を既定の `SSLContext` で使うため、
**独自 TrustManager による検証迂回をしていない** = トラストストアの効果をそのまま見られる。

```bash
# front の JVM から secure-api を直接呼ぶ
curl -s http://localhost:8080/tls-probe/check?target=direct | jq .

# back の JVM から ALB 経由で呼ぶ
curl -s "http://localhost:8180/tls-probe/check?target=alb" | jq .

# 任意 URL / メソッド
curl -s "http://localhost:8080/tls-probe/check?url=https://secure-api:8443/api/v1/items/A1"
curl -s "http://localhost:8080/tls-probe/check?target=direct&method=POST&body=%7B%22a%22%3A1%7D"

# 使用中のトラストストアの中身
curl -s http://localhost:8080/tls-probe/truststore | jq .
```

成功時の応答 (抜粋):

```json
{
  "role": "myapp-front",
  "target": "direct",
  "url": "https://secure-api:8443/api/v1/ping",
  "trustStore": "/tmp/pki/cacerts",
  "ok": true,
  "httpStatus": 200,
  "tls": {
    "protocol": "TLSv1.3",
    "cipherSuite": "TLS_AES_256_GCM_SHA384",
    "peerChainLength": 2,
    "peerSubject": "CN=secure-api,OU=Local Test PKI,...",
    "peerIssuer": "CN=Local Test Intermediate CA,...",
    "peerSans": "2:secure-api, 2:secure-api.local, 2:localhost, 7:127.0.0.1",
    "topOfPresentedChain": "CN=Local Test Intermediate CA,..."
  },
  "responseBody": "{\"status\":\"ok\",...}"
}
```

失敗時は HTTP 502 と、原因の例外チェーン + `hint` が返る。

```json
{
  "ok": false,
  "error": {
    "type": "javax.net.ssl.SSLHandshakeException",
    "message": "PKIX path building failed: ...",
    "hint": "サーバ証明書を検証できません。CA (または自己署名証明書) が JVM トラストストアに 取り込まれていない可能性があります (/tls-probe/truststore で確認)"
  }
}
```

### 6-3. ホストから直接叩く

```bash
# CA を取り出す (verify-tls.sh が .pki-out/ へ出力する)
docker compose exec -T pki-init cat /pki/ca/ca-chain.crt > ca-chain.crt

curl --cacert ca-chain.crt https://localhost:8543/api/v1/ping
curl --cacert ca-chain.crt --resolve alb:9443:127.0.0.1 https://alb:9443/secure/v1/ping
```

`--resolve` を使うのは、ALB 証明書の SAN が `DNS:alb` のため
(`DNS:localhost` も入れてあるので `https://localhost:9443/...` でも検証できる)。

---

## 7. 証明書を作り直す

```bash
docker compose run --rm -e PKI_FORCE_REGENERATE=1 pki-init --oneshot
docker compose restart secure-api alb app-front app-back
```

front/back は起動のたびに cacerts をコピーし直して取り込むため、再起動だけで反映される。
volume ごと消す場合は `docker compose down -v` (MySQL 等のデータも消えるので注意)。

---

## 8. 実 AWS への読み替え

| ローカル | 実 AWS |
|---|---|
| `pki-init` (openssl) | AWS Private CA (ACM PCA) / 社内 CA |
| `secure-api` (WireMock HTTPS) | 自己署名証明書で HTTPS を要求する外部 API / 社内システム |
| `alb` の HTTPS リスナー | ALB の HTTPS リスナー + ACM 証明書 |
| `/secure/*` の `proxy_ssl_*` | ターゲットグループのプロトコル = HTTPS (再暗号化) |
| entrypoint の `keytool` 取り込み | 同じ。ECS では証明書を **S3 / Secrets Manager / SSM から取得**して<br>`PKI_TRUST_DIR` へ配置する処理に置き換える (もしくはイメージへ同梱) |
| named volume `pki` | EFS / サイドカーで取得したファイル / イメージ同梱 |

ECS タスク定義へ持ち込む場合の注意:

- `-Djavax.net.ssl.trustStore` を指すファイルは**書き込み可能なパス**に置く
  (`/tmp` など)。読み取り専用ルートファイルシステムを使う場合は tmpfs を割り当てる。
- 証明書をイメージへ同梱するなら、ビルド時に `keytool -importcert` して
  `${JBOSS_HOME}` 配下へ置き、`TRUSTSTORE_IMPORT_REQUIRED=true` で
  取り込み失敗時にタスクを起動させない運用が安全。

---

## 9. トラブルシューティング

| 症状 | 原因 / 対処 |
|---|---|
| `PKIX path building failed` | トラストストアへ取り込めていない。`curl -s http://localhost:8080/tls-probe/truststore` で `importedForThisTest` を確認。空なら `docker compose logs app-front \| grep truststore` |
| `No subject alternative names matching...` | 接続先ホスト名が SAN に無い。`PKI_SECURE_API_SAN` / `PKI_ALB_SAN` へ追加して再生成 |
| nginx が `cannot load certificate` で起動しない | pki-init より先に alb が起動した。`depends_on: pki-init: service_healthy` が効いているか確認。`docker compose logs pki-init` |
| `secure-api` が起動直後に終了する | WireMock のオプション不一致。`docker compose logs secure-api` を確認。使用中の WireMock で `--disable-http` が未対応の場合は、その行を削除して `--port=8080` を無視する運用に切り替える (HTTPS 経路の検証内容は変わらない) |
| front/back の起動が遅い | EAP の `start_period` が 120s。`tls-verifier` は最大 `WAIT_SECONDS` (既定 180s) 待つ |
| ALB 証明書を切り替えても変わらない | `nginx -s reload` に失敗している。`./alb-tls-cert.sh status` で確認 |
| ホストから `https://localhost:9443` が検証エラー | ALB 証明書の CN は `alb.example.internal`。SAN の `localhost` を使うか `--resolve alb:9443:127.0.0.1` を付ける |

---

## 10. セキュリティ上の注意 (テスト環境専用)

- 秘密鍵はパスフレーズ無し・`mode 0644` で volume に置いている
  (コンテナごとに実行ユーザが異なるため)。**本番でこの構成にしないこと。**
- キーストアのパスワードは `changeit` (JDK 既定値) を直書きしている。
- 生成される証明書はすべてローカル検証専用で、外部から検証できる CA では発行されない。
