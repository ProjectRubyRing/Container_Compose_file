# 自己証明書 (cacert.crt) による HTTPS 検証 (secure-api / JDK・JBoss トラストストア / ALB)

自己署名 CA (**`cacert.crt`**) が発行した証明書でのみ HTTPS を受け付ける REST API サーバを
テスト用の接続先として用意し、**呼び出し元の app-front / app-back が `cacert.crt` を
JDK と JBoss (Elytron) の両方のトラストストアへ取り込むことで、アプリコードを無改変のまま
REST API を呼び出せる**ことを検証する構成。ALB (HTTPS リスナー) 経由でも同様に検証できる。

信頼の起点は **`cacert.crt` 1 枚に一本化**してある。実運用で
「社内 CA の自己署名ルート証明書を `cacert.crt` という名前で配布し、`keytool` で
JDK 同梱 `cacerts` と JBoss のトラストストアへインポートする」運用と同じ形。

---

## 1. 全体像

```
                          ┌──────────────────────────────────────────┐
                          │ pki-init (openssl)                        │
                          │  cacert.crt (自己署名 CA) → 各サーバ証明書 │
                          └──────────────┬───────────────────────────┘
                                         │ named volume: pki (読み取り専用で共有)
        ┌────────────────────────────────┼─────────────────────────────┐
        │                                │                             │
        ▼                                ▼                             ▼
┌────────────────────┐  (C) 直接 HTTPS ┌──────────────┐      ┌────────────────┐
│  app-front         │ ───────────────▶│  secure-api  │      │  alb (nginx)   │
│  app-back          │                 │  WireMock    │◀─────│  HTTPS :443    │
│  (JBoss EAP)       │ ──(E) ALB 経由─▶ │  HTTPS のみ  │ (B) 再暗号化 (HTTPS)  │
│                    │                 │  :8443       │      │  HTTP  :80     │
│ entrypoint が      │                 └──────────────┘      └────────────────┘
│ cacert.crt を      │   ★接続先: cacert.crt 発行の証明書だけを提示    ▲
│ keytool で 2 か所へ │                                                │
│  1. JDK cacerts    │                                                │
│  2. JBoss(Elytron) │                                                │
└────────────────────┘                                                │
        ▲                                                             │
        └──────────────── tls-verifier (curl/openssl/jq) ─────────────┘
                          上記すべてを機械的に検証する
```

| サービス | 役割 | ポート (ホスト:コンテナ) |
|---|---|---|
| `pki-init` | 自己証明書 `cacert.crt` と各サーバ証明書を発行し named volume `pki` へ配置 | なし |
| `secure-api` | **HTTPS でのみ**待ち受ける REST API (WireMock)。★接続確認用のテスト接続先 | `8543:8443` |
| `alb` | ALB 代替。HTTPS リスナーを追加 (証明書適用) | `9080:80` / **`9443:443`** |
| `app-front` / `app-back` | `cacert.crt` を JDK / JBoss 両トラストストアへ取り込み、`tls-probe` から HTTPS 呼び出し | `8080` / `8180` |
| `tls-verifier` | 検証専用コンテナ (`profiles: verify`) | なし |

---

## 2. 発行する証明書 (pki-init)

`compose/pki/gen-certs.sh` が起動時に一度だけ発行する (冪等。2 回目以降は再利用)。

```
/pki/
  ca/cacert.crt|key               ★自己証明書 = 自己署名 CA (CA:TRUE pathlen:0)
                                    これ 1 枚が唯一のトラストアンカー
  secure-api/server.crt|key       secure-api のサーバ証明書 (cacert 発行)
  secure-api/fullchain.crt        リーフ + cacert
  secure-api/server.p12           WireMock(Jetty) 用 PKCS#12 キーストア
  alb/ca-issued/server.crt|key    ALB 用 ★パターンA: cacert 発行
  alb/selfsigned/server.crt|key   ALB 用 ★パターンB: 自己署名リーフ
  rds-proxy/server.crt|key        MySQL (RDS Proxy 相当, cacert 発行)
  trust/cacert.crt                ★front/back のトラストストアへ入れる本命 (alias=cacert)
  trust/alb-selfsigned.crt        ALB 自己署名リーフを使うとき用 (alias=alb-selfsigned)
```

`trust/` 配下のファイル名 (拡張子を除く) が、そのまま `keytool` の alias になる。

SAN (subjectAltName) はコンテナ名で名前解決できるように設定している。

| 証明書 | CN | SAN |
|---|---|---|
| secure-api | `secure-api` | `DNS:secure-api, DNS:secure-api.local, DNS:localhost, IP:127.0.0.1` |
| ALB (両パターン) | `alb.example.internal` | `DNS:alb, DNS:alb.local, DNS:alb.example.internal, DNS:localhost, IP:127.0.0.1` |
| MySQL (rds-proxy) | `mysql` | `DNS:mysql, DNS:mysql.local, DNS:localhost, IP:127.0.0.1` |

### なぜルート CA + 中間 CA の 2 階層をやめたのか

以前は「ルート CA (自己署名) → 中間 CA → 各サーバ証明書」の 3 階層だったが、
**取り込む対象を `cacert.crt` 1 枚に固定**して、
「この 1 枚をトラストストアへ入れたから通っている」ことを一目で示せるようにした。
チェーン検証は `openssl verify -CAfile cacert.crt <leaf>` だけで完結する
(中間証明書 `-untrusted` の指定が不要)。

### 意図的に 2 つの信頼形態を用意している

「その自己証明書そのものをインポート」「CA 証明書をインポート」の**両方**を検証するため。

| | パターン A: CA 発行 | パターン B: 自己署名リーフ |
|---|---|---|
| 使う場所 | `secure-api` / ALB(`ca-issued`) / MySQL | ALB(`selfsigned`) |
| トラストストアに入れるもの | **`cacert.crt` (自己署名 CA)** | **サーバ証明書そのもの** |
| サーバ証明書を再発行したとき | CA が同じならトラストストア更新**不要** | 毎回トラストストアの更新が**必要** |
| 実 AWS での相当 | ACM (Private CA 発行 / インポート) | 自己署名証明書を ACM にインポート |

---

## 3. トラストストアへの取り込み (front / back)

`docker/front/entrypoint.sh` と `docker/back/entrypoint.sh` の
`import_trusted_certs()` が起動時に実行する。**アプリコードは無改変**。
取り込み先は **2 か所**。

```
1. /mnt/pki/trust/*.crt があるか確認 (無ければスキップして通常起動)

2. [JDK 側] JDK 同梱の cacerts を探して /tmp/pki/cacerts へコピー
     ${JAVA_HOME}/lib/security/cacerts → /etc/pki/java/cacerts → java の実体から逆引き
   keytool -importcert で *.crt を追加 (alias = ファイル名から拡張子を除いたもの)
   JAVA_TOOL_OPTIONS に -Djavax.net.ssl.trustStore=/tmp/pki/cacerts を追加

3. [JBoss 側] ${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12 を
   毎起動で削除 → keytool -importcert で *.crt を PKCS12 として作り直す
   (ビルド時に定義済みの Elytron key-store=appTrustStore がこのパスを参照する)
```

### JDK 側と JBoss 側で何が違うのか

| | JDK 側 | JBoss (Elytron) 側 |
|---|---|---|
| 実体 | `/tmp/pki/cacerts` (JDK 同梱 cacerts のコピー + `cacert.crt`) | `${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12` |
| 中身 | パブリック CA **約 150 枚** + 自己証明書 | **自己証明書のみ** (パブリック CA は 0 枚) |
| 効き方 | `-Djavax.net.ssl.trustStore` = JVM 既定の `SSLContext` | Elytron の `trust-manager` / `client-ssl-context` |
| 使われる場所 | アプリの `HttpClient` / JDBC ドライバ (DB の `VERIFY_IDENTITY`) など JVM 全体 | EAP のサブシステム (client-ssl-context / undertow / remoting / resource-adapter) |

実運用でも次の 2 系統を両方行うことが多いため、ローカルでも両方を再現して
**どちらの経路でも同じ HTTPS 接続が通ること**を確認できるようにしている。

```bash
keytool -import -alias cacert -file cacert.crt -keystore $JAVA_HOME/lib/security/cacerts
keytool -import -alias cacert -file cacert.crt \
        -keystore $JBOSS_HOME/standalone/configuration/jboss-truststore.p12 -storetype PKCS12
```

### JBoss 側の Elytron 定義 (ビルド時)

`docker/cli/elytron-truststore.cli` を front/back 双方の Dockerfile で実行している。

```
/subsystem=elytron/key-store=appTrustStore:add(
    path=jboss-truststore.p12, relative-to=jboss.server.config.dir,
    type=PKCS12, required=false,
    credential-reference={clear-text=${env.JBOSS_TRUSTSTORE_PASSWORD:changeit}})
/subsystem=elytron/trust-manager=appTrustManager:add(key-store=appTrustStore)
/subsystem=elytron/client-ssl-context=appClientSslContext:add(
    trust-manager=appTrustManager, protocols=["TLSv1.3","TLSv1.2"])
```

- **ストアの実体を作るのは entrypoint** (起動のたびに再生成)。CLI は位置の定義だけ。
- `required=false` にしているのは、`pki` volume を付けずに起動した場合でも
  EAP が起動に失敗しないようにするため (空のストアとして扱われる)。
- Elytron の `default-ssl-context` は**あえて設定していない**。設定すると JVM 既定の
  `SSLContext` まで置き換わり、「JDK 経由」と「JBoss 経由」を区別して検証できなくなる。

### なぜ JDK 側はコピーしてから使うのか

- コンテナは `jboss` (UID 185) で動くため、root 所有の
  `${JAVA_HOME}/lib/security/cacerts` を直接書き換えられない。
- **コピー元は JDK 同梱の cacerts なので、パブリック CA の信頼はそのまま残る。**
  自己証明書を「追加」するだけで既存の信頼関係を壊さない。
- 毎起動でコピーし直すため alias の重複エラーが起きず、証明書を作り直しても
  コンテナを再起動するだけで最新が反映される (JBoss 側も同じ理由で毎起動作り直す)。

### なぜ `JAVA_TOOL_OPTIONS` か

`JAVA_OPTS_APPEND` (JBoss 標準) でも渡せるが、`JAVA_TOOL_OPTIONS` は JVM が必ず
解釈するため、`jboss-cli` など補助 JVM からも同じトラストストアが使われる。
既存の ADOT Java Agent (`-javaagent`) と同じ変数に追記している。

### 環境変数

| 変数 | 既定値 | 説明 |
|---|---|---|
| `PKI_TRUST_DIR` | `/mnt/pki/trust` | 取り込む `*.crt` の置き場 |
| `JVM_TRUSTSTORE_FILE` | `/tmp/pki/cacerts` | JDK 側トラストストアの生成先 |
| `JVM_TRUSTSTORE_PASSWORD` | `changeit` | コピー元 cacerts のパスワード (JDK 既定値) |
| `JBOSS_TRUSTSTORE_FILE` | `${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12` | JBoss 側トラストストアの生成先。`elytron-truststore.cli` の `path` と一致必須 |
| `JBOSS_TRUSTSTORE_PASSWORD` | `changeit` | JBoss 側トラストストアのパスワード |
| `TRUSTSTORE_IMPORT_REQUIRED` | `false` | `true` にすると取り込み失敗で起動を中止する |

JDK 側の `trustStoreType` は**あえて指定していない** (JKS / PKCS12 は JDK が自動判別するため。
明示するとコピー元の形式が変わったときに読めなくなる)。JBoss 側は自前で作るので `PKCS12` 固定。

---

## 4. テスト用の接続先 (secure-api)

app-front / app-back が「トラストストアへ取り込んだ `cacert.crt` で接続できるか」を
確認するための接続先。WireMock を `--disable-http` 付きで起動し、
**平文 HTTP のポートを一切 listen しない**。
サーバ証明書は pki-init が `cacert.crt` で発行した PKCS#12 をそのまま渡すため、
**`cacert.crt` を信頼していないクライアントは必ず PKIX エラーで弾かれる**。

```yaml
command:
  - --https-port=8443
  - --https-keystore=/pki/secure-api/server.p12   # cacert 発行の証明書 + 鍵 (+ cacert 同梱)
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
  tls/variants/10-server-cert.selfsigned.conf   #   切り替え元 (自己署名リーフ)
  tls/variants/10-server-cert.ca-issued.conf    #   切り替え元 (cacert.crt 発行)
```

HTTPS リスナーのルーティング (`rules-tls/10-secure-routes.conf`):

| パス | 転送先 | 実 ALB での相当 |
|---|---|---|
| `/secure/*` | `https://secure-api:8443/api/*` | ターゲットグループのプロトコル = **HTTPS** (再暗号化) |
| `/async/*`, `/` | `http://app-back:8180` | ターゲットグループのプロトコル = HTTP (ALB で TLS 終端) |

`/secure/*` では `proxy_ssl_verify on` + `proxy_ssl_trusted_certificate /pki/ca/cacert.crt`
でターゲット証明書も検証している (実 ALB はターゲット証明書を検証しないため、
挙動を合わせたい場合は `proxy_ssl_verify off` にする)。

### 証明書の切り替え

```bash
./alb-tls-cert.sh selfsigned   # 自己署名リーフ証明書を適用 (既定)
./alb-tls-cert.sh ca-issued    # cacert.crt 発行の証明書を適用
./alb-tls-cert.sh status       # 適用中の設定と、実際に提示される証明書を表示
```

証明書ファイルは volume に発行済みなので、**切り替えは nginx の reload だけで即時**。
どちらに切り替えても front/back のトラストストアは更新不要
(`cacert.crt` と `alb-selfsigned.crt` の両方を取り込み済みのため)。

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
| 0 | `cacert.crt` が自己署名 + `CA:TRUE`、旧レイアウトが残っていない | OK |
| 0 | `cacert.crt` **1 枚で** secure-api / alb(ca-issued) / rds-proxy を検証できる | OK |
| 2 | `secure-api:8080` (平文 HTTP) が listen していない | 接続不可 |
| 3 | **`cacert.crt` を信頼しない**クライアントからの HTTPS | **失敗** (対照実験) |
| 4 | `cacert.crt` を信頼したクライアントからの REST 呼び出し | 200 / 201 |
| 5 | サーバが提示するチェーン (openssl s_client) | `Verify return code: 0 (ok)` |
| 6 | ALB(HTTPS) → secure-api(再暗号化) | 200 |
| 7 | front/back の **JDK 側と JBoss 側の両方**に `alias=cacert` が入っている | 両方 OK |
| 8 | **front/back の JVM から直接 HTTPS 呼び出し** (`trust=jdk` / `trust=jboss`) | 両方 200 |
| 9 | **front/back の JVM から ALB 経由で呼び出し** (`trust=jdk` / `trust=jboss`) | 両方 200 |
| 10 | **空のトラストストア** (`trust=none`) での呼び出し | **失敗** (対照実験) |

項目 3 と 10 が「失敗」することが重要で、これにより
**「トラストストアへ `cacert.crt` を取り込んだから通っている」**ことが証明される。

### 6-2. front / back の JVM から個別に確認する (tls-probe)

`docker/probe/` の `tls-probe.war` を front と back の両方に配備している。
`trust` パラメータで**どのトラストストアで検証するか**を切り替えられる。

| `trust` | 使うトラストストア | 期待値 |
|---|---|---|
| `jdk` (既定) | JVM 既定の `SSLContext` (= `/tmp/pki/cacerts`)。**アプリコード無改変の経路** | 成功 |
| `jboss` | `jboss-truststore.p12` (Elytron の `appTrustStore` と同じファイル) | 成功 |
| `none` | 空のトラストストア | **失敗** (対照実験) |

```bash
# front の JVM から secure-api を直接呼ぶ (JDK 側トラストストア)
curl -s "http://localhost:8080/tls-probe/check?target=direct&trust=jdk" | jq .

# 同じ呼び出しを JBoss 側トラストストアで
curl -s "http://localhost:8080/tls-probe/check?target=direct&trust=jboss" | jq .

# back の JVM から ALB 経由で呼ぶ
curl -s "http://localhost:8180/tls-probe/check?target=alb&trust=jboss" | jq .

# 対照実験: 空のトラストストア (502 になるのが正しい)
curl -s "http://localhost:8080/tls-probe/check?target=direct&trust=none" | jq .

# 任意 URL / メソッド
curl -s "http://localhost:8080/tls-probe/check?url=https://secure-api:8443/api/v1/items/A1"
curl -s "http://localhost:8080/tls-probe/check?target=direct&method=POST&body=%7B%22a%22%3A1%7D"

# 2 つのトラストストアの中身を同時に確認
curl -s http://localhost:8080/tls-probe/truststore | jq .
```

成功時の応答 (抜粋):

```json
{
  "role": "myapp-front",
  "target": "direct",
  "url": "https://secure-api:8443/api/v1/ping",
  "trust": "jboss",
  "trustStore": "/opt/server/standalone/configuration/jboss-truststore.p12",
  "ok": true,
  "httpStatus": 200,
  "tls": {
    "protocol": "TLSv1.3",
    "cipherSuite": "TLS_AES_256_GCM_SHA384",
    "peerChainLength": 2,
    "peerSubject": "CN=secure-api,OU=Local Test PKI,...",
    "peerIssuer": "CN=Local Test Self-Signed CA,...",
    "peerSans": "2:secure-api, 2:secure-api.local, 2:localhost, 7:127.0.0.1",
    "topOfPresentedChain": "CN=Local Test Self-Signed CA,..."
  },
  "responseBody": "{\"status\":\"ok\",...}"
}
```

`/tls-probe/truststore` の応答 (抜粋):

```json
{
  "role": "myapp-front",
  "elytron": {
    "keyStore": "appTrustStore",
    "trustManager": "appTrustManager",
    "clientSslContext": "appClientSslContext"
  },
  "stores": {
    "jdk": {
      "path": "/tmp/pki/cacerts",
      "readable": true,
      "totalEntries": 152,
      "hasCacert": true,
      "importedForThisTest": ["cacert => CN=Local Test Self-Signed CA,...",
                              "alb-selfsigned => CN=alb.example.internal,..."]
    },
    "jboss": {
      "path": "/opt/server/standalone/configuration/jboss-truststore.p12",
      "readable": true,
      "totalEntries": 2,
      "hasCacert": true,
      "importedForThisTest": ["cacert => CN=Local Test Self-Signed CA,...",
                              "alb-selfsigned => CN=alb.example.internal,..."]
    }
  }
}
```

`jdk` の `totalEntries` が 150 前後 (パブリック CA 込み)、`jboss` が 2 になるのが正しい。
**両方の `hasCacert` が `true`** であることが、この検証の中心。

失敗時は HTTP 502 と、原因の例外チェーン + `hint` が返る。

```json
{
  "ok": false,
  "trust": "jdk",
  "error": {
    "type": "javax.net.ssl.SSLHandshakeException",
    "message": "PKIX path building failed: ...",
    "hint": "サーバ証明書を検証できません。自己証明書 cacert.crt が JDK 側トラストストアに取り込まれていない可能性があります (/tls-probe/truststore で確認)"
  }
}
```

### 6-3. ホストから直接叩く

```bash
# 自己証明書を取り出す (verify-tls.sh が .pki-out/ へ出力する)
docker compose exec -T pki-init cat /pki/ca/cacert.crt > cacert.crt

curl --cacert cacert.crt https://localhost:8543/api/v1/ping
curl --cacert cacert.crt --resolve alb:9443:127.0.0.1 https://alb:9443/secure/v1/ping
```

`--resolve` を使うのは、ALB 証明書の SAN が `DNS:alb` のため
(`DNS:localhost` も入れてあるので `https://localhost:9443/...` でも検証できる)。

---

## 7. 証明書を作り直す

```bash
docker compose run --rm -e PKI_FORCE_REGENERATE=1 pki-init --oneshot
docker compose restart secure-api alb app-front app-back
```

front/back は起動のたびに JDK 側 cacerts をコピーし直し、JBoss 側ストアも削除して
作り直すため、再起動だけで反映される。
volume ごと消す場合は `docker compose down -v` (MySQL 等のデータも消えるので注意)。

> 旧レイアウト (`ca/root-ca.crt` / `ca/intermediate-ca.crt` / `ca/ca-chain.crt` /
> `trust/10-local-test-root-ca.crt` など) が volume に残っていると、古い CA で発行された
> 証明書を掴むことがある。`gen-certs.sh` は再生成時にこれらを明示的に削除するため、
> `PKI_FORCE_REGENERATE=1` での作り直しで移行できる (`down -v` は不要)。

---

## 8. 実 AWS への読み替え

| ローカル | 実 AWS |
|---|---|
| `pki-init` の `cacert.crt` | AWS Private CA (ACM PCA) のルート CA / 社内 CA の自己署名証明書 |
| `secure-api` (WireMock HTTPS) | 自己証明書で HTTPS を要求する外部 API / 社内システム |
| `alb` の HTTPS リスナー | ALB の HTTPS リスナー + ACM 証明書 |
| `/secure/*` の `proxy_ssl_*` | ターゲットグループのプロトコル = HTTPS (再暗号化) |
| entrypoint の `keytool` 取り込み (JDK / JBoss) | 同じ。ECS では証明書を **S3 / Secrets Manager / SSM から取得**して<br>`PKI_TRUST_DIR` へ配置する処理に置き換える (もしくはイメージへ同梱) |
| named volume `pki` | EFS / サイドカーで取得したファイル / イメージ同梱 |

ECS タスク定義へ持ち込む場合の注意:

- `-Djavax.net.ssl.trustStore` を指すファイルは**書き込み可能なパス**に置く
  (`/tmp` など)。読み取り専用ルートファイルシステムを使う場合は tmpfs を割り当てる。
  JBoss 側の `jboss-truststore.p12` (`${JBOSS_HOME}/standalone/configuration/`) も同様。
- 証明書をイメージへ同梱するなら、ビルド時に `keytool -importcert` して
  `${JBOSS_HOME}` 配下へ置き、`TRUSTSTORE_IMPORT_REQUIRED=true` で
  取り込み失敗時にタスクを起動させない運用が安全。
- 読み取り専用ルートファイルシステムで JBoss 側ストアを再生成できない場合は、
  ビルド時に `jboss-truststore.p12` を作り込み、`required=true` に変更しておくと
  「ストアが空のまま起動して実行時に PKIX で落ちる」事故を防げる。

---

## 9. トラブルシューティング

| 症状 | 原因 / 対処 |
|---|---|
| `PKIX path building failed` (`trust=jdk`) | JDK 側へ取り込めていない。`curl -s http://localhost:8080/tls-probe/truststore \| jq .stores.jdk` で `hasCacert` を確認。`false` なら `docker compose logs app-front \| grep 'truststore\[jdk\]'` |
| `PKIX path building failed` (`trust=jboss`) | JBoss 側ストアが空か古い。`docker compose logs app-front \| grep 'truststore\[jboss\]'`。ファイルを作れていない場合は `${JBOSS_HOME}/standalone/configuration` の書き込み権限 (UID 185) を確認 |
| `トラストストアを読めません: .../jboss-truststore.p12` | entrypoint がストアを生成する前に落ちている。`PKI_TRUST_DIR` に `*.crt` があるか確認 |
| EAP 起動時に `appTrustStore` 関連の WARN | ストアファイルが未生成のまま起動した (`required=false` のため起動自体は成功する)。pki volume のマウントと `depends_on: pki-init` を確認 |
| `No subject alternative names matching...` | 接続先ホスト名が SAN に無い。`PKI_SECURE_API_SAN` / `PKI_ALB_SAN` へ追加して再生成 |
| tls-verifier が「旧レイアウトが残っています」で FAIL | `PKI_FORCE_REGENERATE=1` で作り直す (手順は 7 章) |
| nginx が `cannot load certificate` で起動しない | pki-init より先に alb が起動した。`depends_on: pki-init: service_healthy` が効いているか確認。`docker compose logs pki-init` |
| `secure-api` が起動直後に終了する | WireMock のオプション不一致。`docker compose logs secure-api` を確認。使用中の WireMock で `--disable-http` が未対応の場合は、その行を削除して `--port=8080` を無視する運用に切り替える (HTTPS 経路の検証内容は変わらない) |
| front/back の起動が遅い | EAP の `start_period` が 120s。`tls-verifier` は最大 `WAIT_SECONDS` (既定 180s) 待つ |
| ALB 証明書を切り替えても変わらない | `nginx -s reload` に失敗している。`./alb-tls-cert.sh status` で確認 |
| ホストから `https://localhost:9443` が検証エラー | ALB 証明書の CN は `alb.example.internal`。SAN の `localhost` を使うか `--resolve alb:9443:127.0.0.1` を付ける |

---

## 10. セキュリティ上の注意 (テスト環境専用)

- 秘密鍵はパスフレーズ無し・`mode 0644` で volume に置いている
  (コンテナごとに実行ユーザが異なるため)。**本番でこの構成にしないこと。**
- キーストア / トラストストアのパスワードは `changeit` (JDK 既定値) を直書きしている。
- 生成される証明書はすべてローカル検証専用で、外部から検証できる CA では発行されない。
- `cacert.crt` は `CA:TRUE` の CA 証明書。これをトラストストアへ入れるということは
  **この CA が発行した任意の証明書を信頼する**という意味になる。本番で社内 CA を
  取り込む場合も同じ性質になるため、CA 鍵の管理範囲を必ず確認すること。
