# 自己証明書 (cacert.crt) による HTTPS 検証 (secure-api / JDK・JBoss トラストストア / ALB)

HTTPS でのみ待ち受ける REST API サーバをテスト用の接続先として用意し、
**呼び出し元の app-front / app-back が自己証明書 `cacert.crt` を
JDK と JBoss (Elytron) の両方のトラストストアへ取り込むことで、アプリコードを無改変のまま
REST API を呼び出せる**ことを検証する構成。ALB (HTTPS リスナー) 経由でも同様に検証できる。

信頼の起点は **`cacert.crt` 1 枚に一本化**してある。実運用で
「社内 CA の自己署名ルート証明書を `cacert.crt` という名前で配布し、`keytool` で
JDK 同梱 `cacerts` と JBoss のトラストストアへインポートする」運用と同じ形。

> ## ★受領済みの `cacert.crt` を使う (provided モード)
>
> **すでに発行され、連携されてきた `cacert.crt` をそのまま投入できる。**
> `compose/pki/provided/cacert.crt` に置くだけで、`pki-init` は CA を新規発行せず
> 受領物をトラストアンカーとして全コンテナへ配る。
> 置いていない場合は従来どおり自己署名 CA を自動発行する (`generate` モード)。
>
> ```bash
> cp /path/to/受領した/cacert.crt compose/pki/provided/cacert.crt
> docker compose up -d --build
> docker compose logs pki-init | grep 'MODE:'     # provided になっていることを確認
> ./verify-tls.sh
> ```
>
> 置き場を repo 外にしたい場合は `.env` の `PKI_PROVIDED_DIR` でホストパスを指定する。
> 詳細は [`compose/pki/provided/README.md`](../compose/pki/provided/README.md) と本書 2 章。

> ## ★配備した `cacert.crt` をイメージのビルドへ渡す (export → build secret)
>
> `pki-init` が配備した `cacert.crt` は **ホストの `compose/pki/export/` へ自動で出力される**。
> ベースイメージが行っているのと同じ **build secret** 方式でイメージへ焼き込めるほか、
> **そのまま `compose/pki/provided/` へ置くだけ**でその CA を受領物として固定できる。
>
> ```bash
> docker compose up -d pki-init                  # compose/pki/export/cacert.crt が出力される
> docker compose -f compose.yaml -f compose.build-secret.yaml build app-front app-back
> docker compose -f compose.yaml -f compose.build-secret.yaml up -d
> docker compose logs app-front | grep 'truststore\[build\]'
>
> ./pki-export.sh --to-provided                  # この CA を受領物として固定する
> ./pki-export.sh --to ../base-image/secrets     # ベースイメージのビルドコンテキストへ配置
> ```
>
> 詳細は [`compose/pki/export/README.md`](../compose/pki/export/README.md) と本書 3 章。

---

## 1. 全体像

```
      compose/pki/provided/cacert.crt   ← ★受領済み自己証明書 (置けば provided モード)
                          │ bind mount (:ro)                    ▲
                          ▼                                     │ cp / pki-export.sh --to-provided
                          ┌──────────────────────────────────────────┐
                          │ pki-init (openssl)                        │
                          │  cacert.crt (受領物 or 自動発行)          │
                          │    → 各サーバ証明書                       │
                          └──────────────┬───────────────────────────┘
                                         │ bind mount (rw)
                                         ├──▶ compose/pki/export/cacert.crt  ★ホストへ出力
                                         │      └─▶ build secret (id=cacert)
                                         │           └─▶ ベースイメージ / front / back の
                                         │                ビルド時に keytool で焼き込む
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
| `pki-init` | 自己証明書 `cacert.crt` (受領物 or 自動発行) と各サーバ証明書を named volume `pki` へ配置。<br>あわせて `cacert.crt` をホストの `compose/pki/export/` へ**出力**する (ビルドへ渡す用) | なし |
| `secure-api` | **HTTPS でのみ**待ち受ける REST API (WireMock)。★接続確認用のテスト接続先 | `8543:8443` |
| `alb` | ALB 代替。HTTPS リスナーを追加 (証明書適用) | `9080:80` / **`9443:443`** |
| `app-front` / `app-back` | `cacert.crt` を JDK / JBoss 両トラストストアへ取り込み、`tls-probe` から HTTPS 呼び出し | `8080` / `8180` |
| `tls-verifier` | 検証専用コンテナ (`profiles: verify`) | なし |

---

## 2. cacert.crt の入手方法と配備 (pki-init)

`compose/pki/gen-certs.sh` が起動時に一度だけ配備する
(冪等。入力が変わらなければ 2 回目以降は再利用)。

### 2-1. 2 つのモード

| モード | 条件 | `cacert.crt` の出どころ |
|---|---|---|
| **`provided`** ★本命 | `compose/pki/provided/cacert.crt` がある | **受領物をそのままコピー**。CA の新規発行は行わない |
| `generate` | 受領物が無い | `pki-init` が自己署名 CA を発行 (従来動作) |

`PKI_MODE` で明示指定もできる。

| `PKI_MODE` | 動作 |
|---|---|
| `auto` (既定) | 受領物があれば `provided`、無ければ `generate` |
| `provided` | 受領物を必須にする。無ければ **`pki-init` を起動失敗させる** (取り違え防止) |
| `generate` | 受領物があっても無視して自動発行する |

受領した `cacert.crt` を差し替えると、`pki-init` は入力の SHA-256 が変わったことを
`.pki-source` で検知して**自動で PKI を作り直す** (`PKI_FORCE_REGENERATE` は不要)。

受領物は PEM / DER のどちらでも受け取れる (DER なら PEM へ自動変換)。
起動時に「自己署名か / `CA:TRUE` か / 有効期限 / SHA-256」を検査してログへ出す。

### 2-2. 受領物に秘密鍵があるかどうかで発行元が変わる ★重要

**秘密鍵の無い CA 証明書はトラストアンカーとしてしか使えない。**
証明書への署名には CA の秘密鍵が必須なので、`cacert.key` が無い場合、ローカルの
`secure-api` / `alb` / `mysql` が「受領 CA が発行したサーバ証明書」を提示することは
**暗号的に不可能**。そこで役割を分離している。

| | (A) `cacert.crt` + `cacert.key` | (B) `cacert.crt` のみ (鍵なし) |
|---|---|---|
| サーバ証明書の発行元 | **受領 CA** | `local-test-ca` (pki-init が生成) |
| `trust/cacert.crt` (front/back が取り込む) | **受領物** | **受領物** (同じ) |
| `ca/verify-bundle.crt` | `cacert.crt` のみ | `cacert.crt` + `local-test-ca.crt` |
| 受領 `cacert.crt` 単体で HTTPS 検証 | **できる** | できない (鍵が無いため) |
| 受領物で確認できること | 全経路 | **トラストストアへの取り込み** (項目 7) |

```
受領 cacert.crt  → トラストアンカーとして実際に配布・取り込みする対象
                    (JDK / JBoss トラストストアへ入るのは受領物そのもの)
local-test-ca    → サーバ証明書を発行するためだけのローカル CA
```

これにより「受領物が正しく配布・取り込みされているか」は受領物で検証しつつ、
HTTPS / MySQL / ALB といった他の検証項目はブロックされずに実行できる。
`cacert.key` を `compose/pki/provided/` へ置けば**自動的に (A) へ昇格**し、
`local-test-ca` は作られなくなる。

(B) で `PKI_TRUST_LOCAL_CA=0` を指定すると `local-test-ca` をトラストストアへ入れない。
この場合 front/back が信頼するのは受領 `cacert.crt` 1 枚だけになり、
`secure-api` への接続は PKIX で失敗する — **それが期待値**
(= 受領 CA 発行でないサーバ証明書は弾かれる、という対照実験)。
`tls-verifier` はこの構成を自動検知して項目 8 / 9 の期待値を反転する。

### 2-3. 出力レイアウト

```
/pki/
  ca/cacert.crt                   ★自己証明書 (受領物 or 自動発行)。唯一のトラストアンカー
  ca/cacert.key                   その秘密鍵。generate モード / 受領物に鍵がある場合のみ存在
  ca/local-test-ca.crt|key        受領物が鍵なしのときだけ生成する発行専用ローカル CA
  ca/verify-bundle.crt            ★サーバ証明書を検証できる CA の集合
                                    = cacert.crt (+ 鍵なし時のみ local-test-ca.crt)
  secure-api/server.crt|key       secure-api のサーバ証明書
  secure-api/fullchain.crt        リーフ + 発行元 CA
  secure-api/server.p12           WireMock(Jetty) 用 PKCS#12 キーストア
  alb/ca-issued/server.crt|key    ALB 用 ★パターンA: CA 発行
  alb/selfsigned/server.crt|key   ALB 用 ★パターンB: 自己署名リーフ
  rds-proxy/server.crt|key        MySQL (RDS Proxy 相当)
  trust/cacert.crt                ★front/back のトラストストアへ入れる本命 (alias=cacert)
  trust/alb-selfsigned.crt        ALB 自己署名リーフを使うとき用 (alias=alb-selfsigned)
  trust/local-test-ca.crt         鍵なし & PKI_TRUST_LOCAL_CA=1 のときだけ (alias=local-test-ca)
  .pki-ready                      配備完了マーカー (healthcheck が参照)
  .pki-source                     入力のシグネチャ (モード / 受領物の SHA-256)。差し替え検知用
```

`trust/` 配下のファイル名 (拡張子を除く) が、そのまま `keytool` の alias になる。

上記は named volume (`pki`) の中身。**同じ `cacert.crt` はホストの
`compose/pki/export/` にも書き出される**ので、イメージのビルドへ渡したり
`compose/pki/provided/` へ置き直したりできる (3 章)。

`ca/verify-bundle.crt` を参照するのは次の 3 か所。
`cacert.crt` を直接指していないのは、鍵なし受領時に発行元が `local-test-ca` になるため。

| 参照元 | 設定 |
|---|---|
| `mysql` | `--ssl_ca=/mnt/pki/ca/verify-bundle.crt` |
| `alb` (nginx) | `proxy_ssl_trusted_certificate /pki/ca/verify-bundle.crt` |
| `tls-verifier` | `CA_BUNDLE=/pki/ca/verify-bundle.crt` |

### 2-4. 環境変数 (pki-init)

`.env` で設定するもの (受領物の扱いに関わる):

| 変数 | 既定値 | 説明 |
|---|---|---|
| `PKI_PROVIDED_DIR` | `./compose/pki/provided` | 受領物を置く**ホスト**のディレクトリ。`pki-init` へ `/provided` として read-only で bind mount する |
| `PKI_MODE` | `auto` | `auto` / `provided` / `generate` (2-1 参照) |
| `PKI_TRUST_LOCAL_CA` | `1` | 鍵なし受領時に `local-test-ca` をトラストストアへ入れるか |

`compose.yaml` に直書きしているもの (通常は変更不要):

| 変数 | 既定値 | 説明 |
|---|---|---|
| `PKI_FORCE_REGENERATE` | `0` | `1` で毎起動時に作り直す |
| `PKI_DAYS_CA` / `PKI_DAYS_LEAF` | `3650` / `825` | 自動発行時の有効期間 (日) |
| `PKI_CA_CN` | `Local Test Self-Signed CA` | 自動発行時の `cacert.crt` の CN |
| `PKI_LOCAL_CA_CN` | `Local Test Server-Issuing CA (no received key)` | `local-test-ca` の CN |
| `PKI_SECURE_API_SAN` / `PKI_ALB_SAN` / `PKI_RDS_PROXY_SAN` | 各サービス名 + localhost | サーバ証明書の SAN |
| `PKI_KEYSTORE_PASSWORD` | `changeit` | `secure-api/server.p12` のパスワード |

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

## 3. 配備した cacert.crt の出力 (export) と イメージビルドへの受け渡し (build secret)

`pki-init` が配備した `cacert.crt` は、named volume だけでなく
**ホストの `compose/pki/export/` にも自動で書き出される**。
`docker compose up -d pki-init` するだけで出力されるので、追加の操作はいらない。

### 3-1. なぜホストへ出力するのか

証明書の実体は named volume (`pki`) にあり、**コンテナの実行時にしか見えない**。
一方 `docker build` が読めるのは **ビルドコンテキスト (ホスト上のファイル)** だけなので、
イメージのビルドへ証明書を渡すにはホスト側にファイルが必要になる。

社内標準ベースイメージ (`EAP_BASE_IMAGE`) は、BuildKit の **build secret** 経由で
「ビルドコンテキスト上の所定のディレクトリに置いた `cacert.crt`」を受け取り、
JVM のトラストストア (JDK 同梱 `cacerts`) と JBoss EAP (Elytron) のトラストストアへ
取り込んでいる。`compose/pki/export/cacert.crt` はその入力に**そのまま使える**
PEM 1 枚 (中身の書き換えは一切していない)。

```
                pki-init (openssl)
                  cacert.crt を発行 / 受領物をそのまま配備
                        │
        ┌───────────────┴────────────────┐
        ▼                                ▼
 named volume: pki                compose/pki/export/     ★ホスト側 (今回の追加)
   実行時に front/back/mysql/         │
   alb/secure-api が参照              ├──▶ build secret (id=cacert)
        │                             │      └─▶ ベースイメージ / app-front / app-back の
        │                             │           ビルド時に JDK cacerts + jboss-truststore.p12
        ▼                             │           へ keytool で焼き込む
 entrypoint.sh が起動時に             │
 keytool で 2 ストアへ取り込む        └──▶ compose/pki/provided/ へコピー
 (従来からの経路。そのまま残る)              └─▶ 次回以降その CA を「受領物」として固定
```

### 3-2. 出力されるファイル (`compose/pki/export/`)

| ファイル | 内容 | 主な用途 |
|---|---|---|
| **`cacert.crt`** | ★唯一のトラストアンカー (受領物 or 自動発行) | **build secret の入力** / `provided/` へ置いて固定 |
| `cacert.key` | その秘密鍵。存在する場合のみ (`PKI_EXPORT_KEY=0` で抑止) | `provided/` へ一緒に置くとパターン A を維持できる |
| `verify-bundle.crt` | サーバ証明書を検証できる CA の集合 | `curl --cacert` などホストからの検証 |
| `trust/*.crt` | front/back のトラストストアへ入る証明書一式 | 複数証明書をまとめて焼き込むビルドの入力 |
| `MANIFEST.txt` | 出力日時 / モード / SHA-256 指紋 / 各ファイルの sha256 | ビルドへ渡した証明書の同一性確認 |

出力は毎回まるごと作り直す。特に `cacert.key` は「鍵があるか」で `provided` モードの
挙動が変わるため、古い鍵が残って証明書と食い違うことがないよう必ず消してから書く。

`./pki-export.sh` はこの出力を**起動中の `pki-init` から取り出し直し**、
さらに `provided/` やビルドコンテキストへ**配置**するためのヘルパー。

```bash
./pki-export.sh                        # 取り出して compose/pki/export/ へ (+内容表示)
./pki-export.sh --show                 # 出力済みファイルの情報表示のみ
./pki-export.sh --to-provided          # さらに compose/pki/provided/ へ配置 (CA を固定)
./pki-export.sh --to ../base-image/secrets   # さらに任意のディレクトリへ配置
./pki-export.sh --no-key               # 秘密鍵は取り出さない
```

### 3-3. 使い道 1 — build secret でイメージへ焼き込む ★ベースイメージと同じ方式

```bash
docker compose up -d pki-init          # cacert.crt が compose/pki/export/ に出る
ls compose/pki/export/

# app-front / app-back のビルドへ渡す (オーバーレイで build secret を配線)
docker compose -f compose.yaml -f compose.build-secret.yaml build app-front app-back
docker compose -f compose.yaml -f compose.build-secret.yaml up -d

# 素の docker build で渡す場合 (ベースイメージのビルドはこの形)
docker build --secret id=cacert,src=compose/pki/export/cacert.crt \
             --build-arg EAP_BASE_IMAGE=... -f front/Dockerfile ./docker
```

`docker/front/Dockerfile` / `docker/back/Dockerfile` に実装した取り込みは次のとおり
(ベースイメージが行っているのと同じことを、このリポジトリ内で再現している)。

```dockerfile
RUN --mount=type=secret,id=cacert,target=/run/secrets/cacert.crt \
    set -eu; \
    if [ ! -s /run/secrets/cacert.crt ]; then \
      echo "...スキップ..."; \
    else \
      keytool -importcert -noprompt -trustcacerts -alias cacert \
        -file /run/secrets/cacert.crt \
        -keystore "${JAVA_HOME}/lib/security/cacerts" -storepass changeit; \
      keytool -importcert -noprompt -trustcacerts -alias cacert \
        -file /run/secrets/cacert.crt \
        -keystore "${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12" \
        -storetype PKCS12 -storepass changeit; \
      ... /opt/pki/build-import.txt に取り込み記録を残す ... \
    fi
```

| | ビルド時取り込み (build secret) | 実行時取り込み (entrypoint) |
|---|---|---|
| 実行ユーザ | `root` → **JDK 同梱 cacerts を直接更新できる** | `jboss` (185) → `/tmp/pki/cacerts` へコピーして追加 |
| JBoss 側ストア | ビルド時に `jboss-truststore.p12` を作り込む | 毎起動で作り直す |
| 証明書の入手元 | build secret (ホストのファイル) | `${PKI_TRUST_DIR}` (named volume) |
| 証明書を差し替えたら | **イメージの再ビルドが必要** | コンテナの再起動だけで反映 |
| `pki` volume 無しで動くか | **動く** (イメージに焼き込み済み) | 動かない (取り込みがスキップされる) |

- **`secret` を渡さなければこの `RUN` は何もしない**ため、従来どおりの
  `docker compose up -d --build` は一切影響を受けない。
- `--mount=type=secret` はビルド中だけ tmpfs にマウントされ、**イメージのレイヤーにも
  ビルドキャッシュにも残らない**。`COPY` で持ち込むのとはここが違う。
- `compose.build-secret.yaml` を本体の `compose.yaml` に統合していないのは、
  compose の `secrets(file:)` は参照先ファイルが無いと `build` が失敗するため。
  `cacert.crt` は `pki-init` を起動して初めて出力されるので、本体に入れると
  まっさらな clone でのビルドが通らなくなる。

取り込まれたことの確認:

```bash
docker compose logs app-front | grep 'truststore\[build\]'
docker compose exec app-front cat /opt/pki/build-import.txt
curl -s http://localhost:8080/tls-probe/truststore | jq -r '.stores[].cacertSha256'
openssl x509 -in compose/pki/export/cacert.crt -noout -fingerprint -sha256   # ↑と一致するはず
```

### 3-4. 使い道 2 — `compose/pki/provided/` へ置いて CA を固定する

出力された `cacert.crt` は **`compose/pki/provided/` へコピーするだけでそのまま使える**
(形式変換もリネームも不要)。次回以降 `pki-init` は `provided` モードになり、
同じ CA を使い続ける = **自動発行した CA を「受領物」として固定できる**。

```bash
cp compose/pki/export/cacert.crt compose/pki/provided/cacert.crt
cp compose/pki/export/cacert.key compose/pki/provided/cacert.key   # 鍵も出ていれば
docker compose restart pki-init
docker compose restart secure-api alb mysql app-front app-back
docker compose logs pki-init | grep -E 'MODE:|SHA-256'
```

`./pki-export.sh --to-provided` がこのコピーを代行する。

`cacert.key` を**一緒に置くかどうか**で 2-2 のパターンが決まる。

| 置いたもの | 結果 |
|---|---|
| `cacert.crt` + `cacert.key` | パターン A — 受領 CA が全サーバ証明書を発行 (指紋も CA も完全に同じまま) |
| `cacert.crt` のみ | パターン B — サーバ証明書は `local-test-ca` が発行。`cacert.crt` はトラストアンカー専用 |

鍵を持ち出したくない場合は `.env` で `PKI_EXPORT_KEY=0` を指定する
(その場合、出力物を `provided/` へ置くと必ずパターン B になる)。

### 3-5. ベースイメージのビルドコンテキストへ直接出力する

出力先そのものをビルドコンテキスト配下へ向けられる。「所定のディレクトリ」が
決まっている場合はこれが一番手数が少ない。

```dotenv
# .env
PKI_EXPORT_DIR=../base-image/secrets
```

`./pki-export.sh --to ../base-image/secrets` でも同じ配置ができる。

### 3-6. 環境変数

| 変数 | 既定値 | 説明 |
|---|---|---|
| `PKI_EXPORT_DIR` | `./compose/pki/export` | 出力先の**ホスト**パス。`pki-init` へ `/export` として read-write で bind mount する。マウントが無ければ出力しない (警告のみ) |
| `PKI_EXPORT_KEY` | `1` | `cacert.key` も出力するか。`0` で出力しない |
| `PKI_BUILD_SECRET_FILE` | `./compose/pki/export/cacert.crt` | `compose.build-secret.yaml` がビルドへ渡すファイル。受領物を直接渡すなら `./compose/pki/provided/cacert.crt` |
| `CACERT_ALIAS` (build arg) | `cacert` | ビルド時取り込みで使う keytool の alias |
| `JVM_TRUSTSTORE_PASSWORD` / `JBOSS_TRUSTSTORE_PASSWORD` (build arg) | `changeit` | ビルド時に書き込む各ストアのパスワード |

### 3-7. 一覧表 (Excel)

本章の内容 (出力ファイル / 環境変数 / 手順 / ビルド時と実行時の違い / トラブル対応 /
実 AWS への読み替え) は **[`PKI-CACERT-EXPORT.xlsx`](PKI-CACERT-EXPORT.xlsx)** に
8 シートの表としてまとめてある。配布・レビュー用にはこちらが早い。

| シート | 内容 |
|---|---|
| `1.概要` | 配備 → 出力 → 受け渡し → 取り込み → 検証 の 6 ステップ |
| `2.出力ファイル` | `compose/pki/export/` に出る各ファイルの出力条件と使い道 |
| `3.build secret` | 渡し方 / Dockerfile 側の実装 / 取り込み先 / 確認方法 |
| `4.ビルド時と実行時` | 2 経路の比較 (実行ユーザ・実体・差し替え時の作業・volume 依存) |
| `5.環境変数` | `.env` / `compose.yaml` / build arg の全変数 |
| `6.手順` | よく使う 4 パターンの手順と期待値 |
| `7.トラブル対応` | 症状 → 原因 → 対処 |
| `8.実AWSへの読み替え` | ローカルと実 AWS の対応 |

xlsx はバイナリで差分レビューできないため、**内容の変更は生成スクリプトを直して再生成する**。

```bash
python docs/tools/gen-pki-cacert-xlsx.py     # 要 openpyxl
```

詳細は [`compose/pki/export/README.md`](../compose/pki/export/README.md) を参照。

---

## 4. トラストストアへの取り込み (front / back)

`docker/front/entrypoint.sh` と `docker/back/entrypoint.sh` の
`import_trusted_certs()` が起動時に実行する。**アプリコードは無改変**。
取り込み先は **2 か所**。

> ビルド時に build secret で焼き込む経路 (3 章) と併用できる。
> `${PKI_TRUST_DIR}` に `*.crt` が無ければこの実行時取り込みはスキップされ、
> **ビルド時に焼き込んだトラストストアがそのまま使われる**。
> ビルド時取り込みの記録がある場合は起動ログに `truststore[build]:` が出る。

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

## 5. テスト用の接続先 (secure-api)

app-front / app-back が「トラストストアへ取り込んだ `cacert.crt` で接続できるか」を
確認するための接続先。WireMock を `--disable-http` 付きで起動し、
**平文 HTTP のポートを一切 listen しない**。
サーバ証明書は pki-init が配備した PKCS#12 をそのまま渡すため、
**発行元 CA を信頼していないクライアントは必ず PKIX エラーで弾かれる**
(発行元は受領 `cacert.crt` に鍵があれば受領 CA、無ければ `local-test-ca`)。

```yaml
command:
  - --https-port=8443
  - --https-keystore=/pki/secure-api/server.p12   # サーバ証明書 + 鍵 (+ 発行元 CA 同梱)
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

## 6. ALB (HTTPS リスナー)

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

`/secure/*` では `proxy_ssl_verify on` + `proxy_ssl_trusted_certificate /pki/ca/verify-bundle.crt`
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

## 7. 検証方法

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
| 0 | `cacert.crt` が自己署名 + `CA:TRUE` + 有効期限内、旧レイアウトが残っていない | OK |
| 0 | 各サーバ証明書を `ca/verify-bundle.crt` で検証できる | OK |
| 0 | 受領 `cacert.crt` **単体で** secure-api を検証できるか | 鍵ありなら OK / 鍵なしなら不可 (情報表示) |
| 2 | `secure-api:8080` (平文 HTTP) が listen していない | 接続不可 |
| 3 | **CA を信頼しない**クライアントからの HTTPS | **失敗** (対照実験) |
| 4 | 発行元 CA を信頼したクライアントからの REST 呼び出し | 200 / 201 |
| 5 | サーバが提示するチェーン (openssl s_client) | `Verify return code: 0 (ok)` |
| 6 | ALB(HTTPS) → secure-api(再暗号化) | 200 |
| 7 | front/back の **JDK 側と JBoss 側の両方**に `alias=cacert` が入っている | 両方 OK |
| 7 | ★`alias=cacert` の **SHA-256 が受領した cacert.crt と一致**する | 両方 一致 |
| 8 | **front/back の JVM から直接 HTTPS 呼び出し** (`trust=jdk` / `trust=jboss`) | 両方 200 |
| 9 | **front/back の JVM から ALB 経由で呼び出し** (`trust=jdk` / `trust=jboss`) | 両方 200 |
| 10 | **空のトラストストア** (`trust=none`) での呼び出し | **失敗** (対照実験) |

項目 3 と 10 が「失敗」することが重要で、これにより
**「トラストストアへ `cacert.crt` を取り込んだから通っている」**ことが証明される。

項目 7 のフィンガープリント照合が、**受領物そのものが取り込まれている**ことの根拠になる
(subject だけでは同名の別証明書と区別できないため)。
受領物が鍵なしの場合、`tls-verifier` はそれを自動検知して項目 0 の扱いを情報表示に切り替え、
`PKI_TRUST_LOCAL_CA=0` のときは項目 8 / 9 の期待値を「失敗」に反転する。

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
      "cacertSha256": "3F:A1:...:9C",
      "importedForThisTest": ["cacert => CN=Local Test Self-Signed CA,...",
                              "alb-selfsigned => CN=alb.example.internal,..."]
    },
    "jboss": {
      "path": "/opt/server/standalone/configuration/jboss-truststore.p12",
      "readable": true,
      "totalEntries": 2,
      "hasCacert": true,
      "cacertSha256": "3F:A1:...:9C",
      "importedForThisTest": ["cacert => CN=Local Test Self-Signed CA,...",
                              "alb-selfsigned => CN=alb.example.internal,..."]
    }
  }
}
```

`jdk` の `totalEntries` が 150 前後 (パブリック CA 込み)、`jboss` が 2 になるのが正しい
(鍵なし受領 + `PKI_TRUST_LOCAL_CA=1` なら `local-test-ca` が加わって 3)。
**両方の `hasCacert` が `true`** であることが、この検証の中心。

さらに `cacertSha256` を**受領した `cacert.crt` のフィンガープリントと突き合わせる**ことで、
「同名の別証明書ではなく、まさに受領した 1 枚が入っている」ことまで確認できる。

```bash
openssl x509 -in .pki-out/cacert.crt -noout -fingerprint -sha256   # 受領物
curl -s http://localhost:8080/tls-probe/truststore | jq -r '.stores[].cacertSha256'
```

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
# 自己証明書と CA バンドルを取り出す (verify-tls.sh が .pki-out/ へ出力する)
docker compose exec -T pki-init cat /pki/ca/cacert.crt        > cacert.crt
docker compose exec -T pki-init cat /pki/ca/verify-bundle.crt > verify-bundle.crt

curl --cacert verify-bundle.crt https://localhost:8543/api/v1/ping
curl --cacert verify-bundle.crt --resolve alb:9443:127.0.0.1 https://alb:9443/secure/v1/ping

# 受領物のフィンガープリント (front/back のトラストストアの中身と突き合わせる)
openssl x509 -in cacert.crt -noout -fingerprint -sha256
curl -s http://localhost:8080/tls-probe/truststore | jq -r '.stores[].cacertSha256'
```

受領した `cacert.crt` に秘密鍵がある場合 (および自動発行モード) は
`verify-bundle.crt` と `cacert.crt` の内容は同一なので、どちらを使ってもよい。

`--resolve` を使うのは、ALB 証明書の SAN が `DNS:alb` のため
(`DNS:localhost` も入れてあるので `https://localhost:9443/...` でも検証できる)。

---

## 8. 証明書を入れ替える / 作り直す

### 7-1. 受領した cacert.crt を差し替える

```bash
cp /path/to/新しい/cacert.crt compose/pki/provided/cacert.crt
docker compose restart pki-init
docker compose restart secure-api alb mysql app-front app-back
docker compose logs pki-init | grep -E 'MODE:|SHA-256'
```

`PKI_FORCE_REGENERATE` は不要。`pki-init` は受領物の SHA-256 を `.pki-source` に
記録しており、差し替えを検知すると自動で PKI 一式を作り直す。

### 7-2. 自動発行モードで作り直す

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

## 9. 実 AWS への読み替え

| ローカル | 実 AWS |
|---|---|
| `compose/pki/provided/cacert.crt` (受領物) | 社内 CA / 取引先から連携される自己署名ルート証明書そのもの |
| `compose/pki/export/cacert.crt` (出力) | CI がビルド前に取得する CA 証明書<br>(S3 / Secrets Manager / SSM / 社内配布サーバから落としてビルドコンテキストへ置く) |
| `--secret id=cacert` でのビルド時取り込み | 同じ。CodeBuild なら `docker build --secret` に<br>Secrets Manager から取得したファイルを渡す (イメージ層に残さない) |
| `pki-init` の `cacert.crt` | AWS Private CA (ACM PCA) のルート CA / 社内 CA の自己署名証明書 |
| `local-test-ca` (鍵なし受領時のみ) | ローカル専用。実 AWS には対応物が無い (受領 CA の鍵を持たないための代替) |
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

## 10. トラブルシューティング

| 症状 | 原因 / 対処 |
|---|---|
| `compose/pki/export/` に何も出力されない | `pki-init` の起動ログに `export: /export が無いため出力しません` が出ていないか確認。出ていれば bind mount が無い (compose.yaml の `${PKI_EXPORT_DIR:-./compose/pki/export}:/export`)。`docker compose up -d pki-init` で作り直すか `./pki-export.sh` で取り出す |
| `WARN: export: /export へ書き込めません` | 出力先を `:ro` でマウントしている。`PKI_EXPORT_DIR` に指定したホストパスの書き込み権限も確認する |
| `docker compose build` が `secret ... no such file or directory` で失敗 | `compose/pki/export/cacert.crt` がまだ無い。先に `docker compose up -d pki-init` (もしくは `./pki-export.sh`) を実行する。`compose.build-secret.yaml` を使うときだけ必要 |
| build secret を渡したのに取り込まれない | ビルドログに `[build][cacert] ... スキップします` が出ていれば secret が届いていない。`-f compose.build-secret.yaml` を付けているか、`docker build` なら `--secret id=cacert,src=...` の `id` が `cacert` かを確認。BuildKit が無効 (`DOCKER_BUILDKIT=0`) でも渡らない |
| ビルド時に取り込んだのに実行時の中身が違う | `${PKI_TRUST_DIR}` に `*.crt` があると JBoss 側ストアは毎起動で作り直される (JDK 側は cacerts のコピーなのでビルド時の分も残る)。`docker compose logs app-front \| grep truststore` で両方の経路を確認 |
| 出力物を `provided/` へ置いたら `cacert.key は cacert.crt の秘密鍵ではありません` | 配置先に**古い `cacert.key` が残っている**。`compose/pki/provided/` の鍵を消してから置き直す (`./pki-export.sh --to-provided` は自動で消す) |
| 受領した `cacert.crt` が使われていない | `docker compose logs pki-init \| grep 'MODE:'` が `generate` なら受領物を認識していない。`compose/pki/provided/cacert.crt` のパス / ファイル名を確認 (`.env` で `PKI_PROVIDED_DIR` を変えている場合はそのパス)。確実に失敗させたいなら `.env` に `PKI_MODE=provided` |
| `cacert.crt を X.509 証明書として読めません` | 受領物が PEM / DER のどちらでもない (テキスト混入、破損、PKCS#7 / PKCS#12 など)。`openssl x509 -in cacert.crt -noout -text` で確認 |
| `cacert.key は cacert.crt の秘密鍵ではありません` | 鍵と証明書の取り違え。`openssl x509 -in cacert.crt -noout -pubkey` と `openssl pkey -in cacert.key -pubout` を比較 |
| 受領物を差し替えたのに反映されない | `pki-init` を再起動していない。`docker compose restart pki-init` 後に `secure-api alb mysql app-front app-back` も再起動する |
| 項目 7 で「受領物と一致しません」 | トラストストアに別の `cacert` が残っている。`docker compose restart app-front app-back` (entrypoint が毎起動で作り直す)。それでも直らなければ `docker compose logs pki-init \| grep SHA-256` と突き合わせる |
| 項目 8 / 9 が `PKIX path building failed` で失敗する (鍵なし受領時) | `PKI_TRUST_LOCAL_CA=0` になっていれば**期待どおり**。正常系も確認したい場合は `1` (既定) に戻すか、`cacert.key` を `compose/pki/provided/` へ置く |
| `PKIX path building failed` (`trust=jdk`) | JDK 側へ取り込めていない。`curl -s http://localhost:8080/tls-probe/truststore \| jq .stores.jdk` で `hasCacert` を確認。`false` なら `docker compose logs app-front \| grep 'truststore\[jdk\]'` |
| `PKIX path building failed` (`trust=jboss`) | JBoss 側ストアが空か古い。`docker compose logs app-front \| grep 'truststore\[jboss\]'`。ファイルを作れていない場合は `${JBOSS_HOME}/standalone/configuration` の書き込み権限 (UID 185) を確認 |
| `トラストストアを読めません: .../jboss-truststore.p12` | entrypoint がストアを生成する前に落ちている。`PKI_TRUST_DIR` に `*.crt` があるか確認 |
| EAP 起動時に `appTrustStore` 関連の WARN | ストアファイルが未生成のまま起動した (`required=false` のため起動自体は成功する)。pki volume のマウントと `depends_on: pki-init` を確認 |
| `No subject alternative names matching...` | 接続先ホスト名が SAN に無い。`PKI_SECURE_API_SAN` / `PKI_ALB_SAN` へ追加して再生成 |
| tls-verifier が「旧レイアウトが残っています」で FAIL | `PKI_FORCE_REGENERATE=1` で作り直す (手順は 8 章) |
| nginx が `cannot load certificate` で起動しない | pki-init より先に alb が起動した。`depends_on: pki-init: service_healthy` が効いているか確認。`docker compose logs pki-init` |
| `secure-api` が起動直後に終了する | WireMock のオプション不一致。`docker compose logs secure-api` を確認。使用中の WireMock で `--disable-http` が未対応の場合は、その行を削除して `--port=8080` を無視する運用に切り替える (HTTPS 経路の検証内容は変わらない) |
| front/back の起動が遅い | EAP の `start_period` が 120s。`tls-verifier` は最大 `WAIT_SECONDS` (既定 180s) 待つ |
| ALB 証明書を切り替えても変わらない | `nginx -s reload` に失敗している。`./alb-tls-cert.sh status` で確認 |
| ホストから `https://localhost:9443` が検証エラー | ALB 証明書の CN は `alb.example.internal`。SAN の `localhost` を使うか `--resolve alb:9443:127.0.0.1` を付ける |

---

## 11. セキュリティ上の注意 (テスト環境専用)

- **受領した証明書 / 秘密鍵はコミットしないこと。** `compose/pki/provided/` は
  `README.md` と `.gitkeep` を除いて `.gitignore` 済み。イメージにも含めない
  (`compose/pki/.dockerignore` でビルドコンテキストから除外している)。
- **出力先 `compose/pki/export/` も同様に `.gitignore` 済み。**
  既定では `cacert.key` (CA の秘密鍵) もここへ出力される。持ち出したくない場合は
  `.env` で `PKI_EXPORT_KEY=0` を指定する。
- ビルドへの受け渡しに `--mount=type=secret` を使っているのは、**イメージのレイヤーにも
  ビルドキャッシュにも残さない**ため。`COPY` で証明書を持ち込むと
  `docker history` / レイヤー展開で取り出せてしまう。CA 証明書自体は公開してよいものだが、
  同じ経路で他の秘密を渡す場合に効いてくる。
- 受領物に `cacert.key` が含まれる場合、それは **CA の秘密鍵** であり、
  持っている人は任意のサーバ証明書を発行できる。ローカル検証用途に限り、
  取り扱い範囲を必ず確認すること。
- 秘密鍵はパスフレーズ無し・`mode 0644` で volume に置いている
  (コンテナごとに実行ユーザが異なるため)。**本番でこの構成にしないこと。**
  受領した `cacert.key` も同じ扱いで volume へコピーされる点に注意。
- キーストア / トラストストアのパスワードは `changeit` (JDK 既定値) を直書きしている。
- 生成される証明書はすべてローカル検証専用で、外部から検証できる CA では発行されない。
- `cacert.crt` は `CA:TRUE` の CA 証明書。これをトラストストアへ入れるということは
  **この CA が発行した任意の証明書を信頼する**という意味になる。本番で社内 CA を
  取り込む場合も同じ性質になるため、CA 鍵の管理範囲を必ず確認すること。
