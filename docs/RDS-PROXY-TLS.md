# MySQL の TLS 挙動を RDS Proxy にそろえる — MY-010068 / MY-013602 の読み方

frontend / backend (JBoss EAP 8.1) から `mysql:8.4.7` へ接続したときに出る

```
[Warning] [MY-010068] [Server] CA certificate ca.pem is self signed.
[System]  [MY-013602] [Server] Channel mysql_main configured to support TLS. Encrypted connections are now supported for this channel.
```

について、**これは何なのか / 本番の RDS Proxy 経由でも起きるのか / ローカルを
RDS Proxy と同じ挙動にそろえるために何を変えたのか**をまとめる。

---

## 0. 結論

| 問い | 答え |
|---|---|
| これはエラーか | **いいえ**。1 行目は Warning、2 行目は System (単なる通知)。接続失敗の原因ではない |
| いつ出るか | **mysqld の起動時**。EAP からの接続時ではない (接続の有無に関わらず出る) |
| 原因 | コミュニティ版 mysqld が初回起動時に**自己署名の CA (`ca.pem`) とサーバ証明書を自動生成**し、それを使って TLS を有効化したため |
| RDS Proxy 経由でも出るか | **アプリからは観測されない**。RDS Proxy はマネージドサービスで mysqld のエラーログを持たず、証明書も Amazon RDS CA 発行のため自動生成の自己署名 CA という状態自体が存在しない |
| では放置してよいか | メッセージ自体は無害。ただし**この状態のローカルは RDS Proxy と TLS の挙動が違う**ので、そこは是正した (下記) |

---

## 1. 2 つのメッセージの正体

### MY-013602 (System) — 「このチャネルで TLS が使えるようになった」

```
[System] [MY-013602] [Server] Channel mysql_main configured to support TLS.
                              Encrypted connections are now supported for this channel.
```

`mysql_main` は **クライアント接続を受け付けるメインのリスナー**を指す内部名
(X Plugin 用の `mysql_x`、レプリカ用チャネルなどと区別するためのもの)。
「このチャネルで暗号化接続をサポートする設定が完了した」という**成功通知**であり、
TLS が有効になっていることの証拠。**出ているのが正常**で、消してはいけない。

Aurora / RDS のエラーログにも同じ行が出る。

### MY-010068 (Warning) — 「CA 証明書が自己署名だ」

```
[Warning] [MY-010068] [Server] CA certificate ca.pem is self signed.
```

mysqld は起動時、`ssl_ca` に指定された CA 証明書の issuer と subject を比較し、
一致した (= 自己署名ルート CA だった) 場合にこの警告を出す。

コミュニティ版イメージは `auto_generate_certs=ON` が既定で、**datadir に
`ca.pem` / `server-cert.pem` / `server-key.pem` が無ければ自動生成**する。
その `ca.pem` は自己署名ルート CA なので、必ずこの警告が出る。

つまり **「TLS の設定に失敗した」ではなく「自動生成の自己署名 CA を使っている」**
という状態の通知。接続はこの状態でも普通に成功する。

> EAP からの接続が実際に失敗している場合、原因はこの 2 行ではなく別にある。
> `WFLYJCA` 系のログ、`XAER_*`、`Public Key Retrieval is not allowed`、
> `PKIX path building failed` などを確認すること (7 章)。

---

## 2. RDS Proxy 経由ではどうなるか

本番の経路は `frontend / backend → RDS Proxy → Aurora MySQL 8.4` で、
アプリが TLS ハンドシェイクする相手は **Aurora ではなく RDS Proxy** になる。

| 観点 | ローカル `mysql:8.4.7` (変更前) | RDS Proxy |
|---|---|---|
| エラーログの参照可否 | `docker compose logs mysql` で見える | **マネージドのため mysqld エラーログは存在しない**。CloudWatch に出るのは Proxy のイベントログのみ |
| サーバ証明書 | 起動時に**自動生成した自己署名証明書** | **Amazon RDS CA 発行** (`rds-ca-rsa2048-g1` 等)。ルート → リージョン中間 CA → エンドポイント証明書 |
| 証明書の CN / SAN | `MySQL_Server_8.4.7_Auto_Generated_Server_Certificate` / **SAN 無し** | Proxy エンドポイントの FQDN |
| MY-010068 相当の状態 | 発生する | **発生しない** (自己署名 CA を自動生成する経路が無い) |
| 平文接続 | 許可される | 「Require Transport Layer Security」有効時は**拒否** |

→ **アプリ側から見て MY-010068 は RDS Proxy 経由では起きない。**
ただし、その理由は「RDS Proxy が偉い」からではなく、
**証明書の出所が違う**からである。そしてこの違いは、放っておくと次の実害になる。

### 実害: ローカルでだけ「検証できない」状態になる

自動生成証明書は **CA 発行でもなく SAN も無い**ため、
`sslMode=VERIFY_CA` / `VERIFY_IDENTITY` を指定すると**ローカルでは必ず失敗する**。
その結果 `sslMode=PREFERRED` のまま検証を進めることになり、以下を見落とす:

- 本番で `VERIFY_IDENTITY` に切り替えた瞬間に `PKIX path building failed` で全滅する
  (Amazon RDS の CA バンドルを JVM トラストストアへ入れ忘れているケース)
- RDS Proxy の「Require TLS」が有効なのに、ローカルでは平文でも通るため
  TLS が張れない設定ミスに気付けない

**ローカルが本番より緩い**、という一番まずいパターン。ここを是正する。

---

## 3. 変更内容

`pki-init` が発行した **CA 発行のサーバ証明書**を mysqld に使わせ、
**平文接続を拒否**することで、RDS Proxy と同じ性質のエンドポイントにそろえた。

| ファイル | 変更 |
|---|---|
| `compose/pki/gen-certs.sh` | `rds-proxy/` に MySQL 用サーバ証明書を発行 (自己証明書 `cacert.crt` 発行、`SAN=DNS:mysql,...`) |
| `compose.yaml` (mysql) | mysqld の TLS 設定を `command:` で指定、`pki` volume をマウント、`depends_on: pki-init`、healthcheck を `--ssl-mode=REQUIRED` に |
| `compose.yaml` (front/back) | `DB_SSL_MODE: VERIFY_IDENTITY` を明示 |
| `docker/cli/mysql-xa-datasource.cli` | `SslMode` の既定を `PREFERRED` → **`VERIFY_IDENTITY`** |
| `docker/front,back/entrypoint.sh` | `DB_SSL_MODE=VERIFY_*` なのにトラストストアが無い場合に警告 |
| `ecs/taskdef.json` | `DB_SSL_MODE=VERIFY_IDENTITY` を明示 |
| `verify-local.sh` | 手順 9 として TLS 挙動の検証を追加 |

### 3.1 証明書 (pki-init)

既存の PKI (自己証明書 `cacert.crt`) をそのまま使い、DB 用のリーフを 1 枚追加する。

```
/pki/ca/cacert.crt               ← Amazon RDS Root CA / global-bundle.pem 相当
                                    (トラストアンカー。受領物 もしくは pki-init が発行)
/pki/ca/verify-bundle.crt        ← mysqld の --ssl_ca に渡す CA バンドル
/pki/rds-proxy/server.crt|key    ← RDS Proxy エンドポイントの証明書相当
/pki/rds-proxy/fullchain.crt     ← mysqld が提示するチェーン (リーフ + 発行元 CA)
```

> `verify-bundle.crt` は「このスタックのサーバ証明書を検証できる CA の集合」。
> 受領した `cacert.crt` に秘密鍵がある場合 (および pki-init の自動発行モード) は
> `cacert.crt` と同一内容になる。受領物が**証明書のみ (鍵なし)** の場合は、
> 受領 CA で署名できないため DB のサーバ証明書は `local-test-ca` が発行し、
> `verify-bundle.crt` は `cacert.crt + local-test-ca.crt` の連結になる。
> 詳細は [TLS-SELF-SIGNED-ALB.md](TLS-SELF-SIGNED-ALB.md) の 2 章を参照。

> 実 AWS の Amazon RDS は「Root CA → リージョン中間 CA → エンドポイント証明書」の
> 3 段だが、ローカルでは**トラストストアへ入れる証明書を 1 枚に固定する**ことを
> 優先して `cacert.crt` へ一本化している。JVM から見た構造
> (「トラストストアに入れた CA が発行したリーフを検証する」) は同じであり、
> 本番で `global-bundle.pem` を取り込む運用にそのまま読み替えられる。

SAN は `DNS:mysql,DNS:mysql.local,DNS:localhost,IP:127.0.0.1`。
front/back は `DB_HOST=mysql` で接続するため **`DNS:mysql` が必須**
(これが無いと `VERIFY_IDENTITY` のホスト名検証で落ちる)。
`PKI_RDS_PROXY_SAN` 環境変数で差し替え可能。

### 3.2 mysqld 側 (`compose.yaml` の `command:`)

```yaml
  mysql:
    image: mysql:8.4.7
    command:
      - --auto_generate_certs=OFF                      # 自己署名の自動生成をやめる
      - --ssl_cert=/mnt/pki/rds-proxy/fullchain.crt
      - --ssl_key=/mnt/pki/rds-proxy/server.key
      - --ssl_ca=/mnt/pki/ca/verify-bundle.crt         # サーバ証明書の発行元 CA
      - --require_secure_transport=ON                  # 平文接続を拒否
      - --tls_version=TLSv1.2,TLSv1.3
```

> ⚠️ **なぜ `my.cnf` ではなく起動引数なのか**
>
> `/etc/mysql/conf.d/*.cnf` へ bind mount する方法は **Windows / macOS の Docker
> Desktop では動かない**。bind mount されたファイルは mode 0777 になり、mysqld は
> world-writable な設定ファイルを**黙って無視する**ためである:
>
> ```
> mysql: [Warning] World-writable config file '/etc/mysql/conf.d/rds-proxy-tls.cnf' is ignored.
> ```
>
> 無視された結果、`auto_generate_certs` が既定の ON に戻り、**自己署名証明書の自動生成
> (= MY-010068) が復活する**。しかもエラーではなく Warning 1 行なので気付きにくい。
> 起動引数ならホスト側のファイルモードに一切依存しないため、OS を問わず同じ挙動になる。
> (この repo の他サービスが設定ファイルを bind mount できているのは、
>  nginx / OTel Collector など権限チェックをしないプロセスだから。)

ポイント:

- **`auto_generate_certs=OFF` + `ssl_cert`/`ssl_key` 指定**で datadir の
  `ca.pem` 自動生成・自動検出が止まる。→ **MY-010068 が出なくなる**
- `ssl_cert` は **fullchain (リーフ + cacert)**。mysqld は
  `SSL_CTX_use_certificate_chain_file()` で読むため、発行元 CA までクライアントへ提示できる。
  中間 CA を挟む構成では、リーフ単体を指定するとクライアントが中間 CA を
  持っていない限り検証に失敗する (本番の RDS 構成ではここが効いてくる)
- **`ssl_ca` は省略してはいけない**。本来はクライアント証明書検証用だが、
  mysqld は起動時に**自分のサーバ証明書もこの CA で検証する**。省略すると

  ```
  [Warning] [MY-015011] Failed to validate certificate ... unable to get local issuer certificate
  [Warning] [MY-015010] Server certificate ... verification has failed
  ```

  が出る (MY-010068 を消したつもりが別の警告に置き換わるだけになる)。
  実 RDS / Aurora も `ssl_ca` に Amazon RDS の CA バンドルを設定している
- `require_secure_transport=ON` は **Unix ソケット接続を対象外**とするため、
  `docker-entrypoint` の初期化 (`init.sql` / `init-infdb.sh` は `--protocol=socket`) は影響を受けない

### 3.3 クライアント側 (XA データソース)

`docker/cli/mysql-xa-datasource.cli` の既定を厳しい側へ寄せた。

```
/subsystem=datasources/xa-data-source=AppXADS/xa-datasource-properties=SslMode:add(
    value=${env.DB_SSL_MODE:VERIFY_IDENTITY})
```

| 値 | 意味 |
|---|---|
| `PREFERRED` (旧既定) | TLS を試みるが、張れなければ**黙って平文へ落ちる** |
| `REQUIRED` | TLS 必須。ただし**証明書は検証しない** (中間者攻撃を検知できない) |
| `VERIFY_CA` | チェーン検証あり。ホスト名は見ない |
| `VERIFY_IDENTITY` (新既定) | チェーン + **ホスト名 (SAN) 検証**。RDS Proxy 接続の推奨設定 |

`VERIFY_*` は「サーバ証明書を発行した CA が JVM トラストストアにあること」が前提。
Connector/J は `trustCertificateKeyStoreUrl` 未指定時に **JVM 既定のトラストストア**
(`-Djavax.net.ssl.trustStore`) を使うため、entrypoint.sh が
`${PKI_TRUST_DIR}/*.crt` を取り込んで指定している既存の仕組みにそのまま乗る。

> ここで効くのは **JDK 側**のトラストストア (`/tmp/pki/cacerts`) であり、
> JBoss (Elytron) 側の `jboss-truststore.p12` ではない。entrypoint.sh は
> 同じ `cacert.crt` を両方へ取り込むため、DB 経路 (JDK 側) と
> HTTPS 経路 (JDK / JBoss 両方) のどちらも同じ 1 枚で成立する。
> 詳細は [docs/TLS-SELF-SIGNED-ALB.md](TLS-SELF-SIGNED-ALB.md) の 3 章を参照。

TLS バージョンの下限はクライアント側では指定せず、**サーバ側 `tls_version` で
強制**している。RDS Proxy も同様にプロキシ側で下限を決めるため、この方が忠実。

---

## 4. 動作確認

```bash
# 証明書とサーバ設定が変わるので、DB volume と PKI volume を作り直す
docker compose down -v
docker compose up -d --build

# 一括検証 (手順 9 が今回の TLS 検証)
./verify-local.sh
```

個別に確認する場合:

```bash
# 1) 自己署名 CA の自動生成が止まっていること (MY-010068 が出ない)
docker compose logs mysql | grep -E "MY-010068|MY-015010|MY-015011" || echo "OK: 警告なし"

# 2) TLS 自体は有効なこと (MY-013602 は出るのが正常)
docker compose logs mysql | grep MY-013602

# 3) mysqld が使っている証明書
docker compose exec mysql mysql -uroot -p"localdev-root-change-me" \
  -e "SHOW VARIABLES WHERE Variable_name IN ('ssl_ca','ssl_cert','ssl_key','require_secure_transport','tls_version','auto_generate_certs');"

# 4) 提示される証明書の issuer / SAN
docker compose exec mysql openssl x509 -in /mnt/pki/rds-proxy/server.crt -noout -issuer -subject -ext subjectAltName

# 5) チェーン + ホスト名検証で接続できること (= 本番と同じ VERIFY_IDENTITY)
docker compose exec mysql sh -c \
  'mysql --ssl-mode=VERIFY_IDENTITY --ssl-ca=/mnt/pki/ca/verify-bundle.crt \
     -h mysql -uappuser -p"$MYSQL_PASSWORD" -D appdb -e "SELECT 1"'

# 6) 平文接続が拒否されること (ERROR 3159 になれば OK)
docker compose exec mysql sh -c \
  'mysql --ssl-mode=DISABLED -h 127.0.0.1 -uappuser -p"$MYSQL_PASSWORD" -e "SELECT 1"'

# 7) EAP が張っているコネクションが暗号化されていること (SSL/TLS と出れば OK)
docker compose exec mysql mysql -uroot -p"localdev-root-change-me" -e \
  "SELECT PROCESSLIST_USER, CONNECTION_TYPE, COUNT(*) FROM performance_schema.threads
    WHERE PROCESSLIST_USER IS NOT NULL GROUP BY 1,2;"

# 8) EAP 側から XA 接続テスト
docker compose exec frontend /opt/server/bin/jboss-cli.sh --connect \
  --controller=127.0.0.1:9990 \
  "/subsystem=datasources/xa-data-source=AppXADS:test-connection-in-pool"
```

---

## 5. 本番 (ECS + RDS Proxy) で必要な作業

`DB_SSL_MODE=VERIFY_IDENTITY` を有効にするには、**Amazon RDS の CA バンドルが
JVM トラストストアに入っている**必要がある。JDK 同梱の `cacerts` には
`Amazon RDS Root 2019 CA` は**含まれていない**ため、入れ忘れると

```
javax.net.ssl.SSLHandshakeException: PKIX path building failed:
  unable to find valid certification path to requested target
```

で XA プールの初期化に失敗する。entrypoint.sh はこの状態を起動時に警告する。

対応は 2 択:

1. **イメージへ焼き込む** (推奨。オフラインでも起動できる)

   ```dockerfile
   # Dockerfile (front/back 共通)
   RUN curl -fsSL -o /opt/pki/trust/40-amazon-rds-global-bundle.crt \
         https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
   ENV PKI_TRUST_DIR=/opt/pki/trust
   ```

2. **`PKI_TRUST_DIR` へマウントする** (EFS / サイドカーで配布する場合)

いずれの場合も entrypoint.sh が `${PKI_TRUST_DIR}/*.crt` を keytool で取り込み、
`-Djavax.net.ssl.trustStore` を JVM へ渡す既存の仕組みがそのまま働く
(同じファイル群は JBoss 側 `jboss-truststore.p12` へも取り込まれる)。

あわせて RDS Proxy 側で:

- **「Require Transport Layer Security」を有効化**する
  (ローカルの `require_secure_transport=ON` と同じ状態にそろえる)
- Proxy エンドポイントの FQDN を `DB_HOST` に設定する。
  `VERIFY_IDENTITY` はこのホスト名を証明書の SAN と突き合わせるため、
  IP アドレスや別名を指定すると失敗する

---

## 6. 今回そろえていない RDS Proxy との差分

TLS の挙動のみをそろえており、**RDS Proxy の本体機能 (コネクションプーリング /
多重化 / フェイルオーバー時の接続保持) はローカルには存在しない**。
これらを模したい場合は別途プロキシコンテナ (ProxySQL 等) の導入が必要で、
XA と `caching_sha2_password` の組み合わせで別の考慮が増えるため、本構成では採用していない。

そのため以下は**ローカルでは検証できない**。本番でのみ確認すること:

| 項目 | 内容 |
|---|---|
| セッションピン留め | XA を使うと RDS Proxy はセッションをピン留めする。`DatabaseConnectionsCurrentlySessionPinned` を監視 (DESIGN.md 4 章) |
| 多重化の影響 | `PinGlobalTxToPhysicalConnection=true` が必須なのはこのため |
| フェイルオーバー | Aurora のフェイルオーバー時、Proxy が接続を保持する挙動 |
| IAM 認証 / Secrets Manager | Proxy 経由の認証方式。本構成は DB ユーザ + パスワード (SSM Parameter Store) |

---

## 7. トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `MY-010068` がまだ出る | 旧 volume が残っていて cnf が効いていない。`docker compose down -v` で作り直す |
| `MY-015010` / `MY-015011` | `ssl_ca` が未指定、または `ssl_cert` がリーフ単体でチェーンが繋がらない。`fullchain.crt` を指定しているか確認 |
| mysqld が起動しない | 証明書ファイルが読めない。`pki-init` が healthy か、`/mnt/pki/rds-proxy/` にファイルがあるか確認 |
| `ERROR 3159 (HY000): Connections using insecure transport are prohibited` | `require_secure_transport=ON` の想定どおりの挙動。クライアント側で TLS を有効にする |
| `PKIX path building failed` | CA が JVM トラストストアに無い。ローカルなら `pki-init` の healthy 待ちと `PKI_TRUST_DIR`、本番なら RDS CA バンドル (5 章) |
| `javax.net.ssl.SSLHandshakeException: ... No subject alternative names matching` | 証明書の SAN に `DB_HOST` の値が含まれていない。`PKI_RDS_PROXY_SAN` を見直して `PKI_FORCE_REGENERATE=1` で再発行 |
| `Public Key Retrieval is not allowed` | 平文接続で `caching_sha2_password` を使ったときのエラー。TLS が張れていない証拠なので、上の TLS 系を先に解決する |

関連ドキュメント:

- [docs/MYSQL-8.4-AURORA-UPGRADE.md](MYSQL-8.4-AURORA-UPGRADE.md) — MySQL 8.4 / Connector/J 9.7.0 化の差分
- [docs/TLS-SELF-SIGNED-ALB.md](TLS-SELF-SIGNED-ALB.md) — HTTPS 経路 (secure-api / ALB) の自己証明書 (cacert.crt) 検証
- [DESIGN.md](../DESIGN.md) — XA データソースの設計とトラブルシューティング
