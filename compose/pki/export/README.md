# 自己証明書 (cacert.crt) の出力口

`pki-init` が配備した自己証明書 `cacert.crt` を**ホスト側へ書き出す**ディレクトリ。
`docker compose up -d pki-init` するだけで自動的に出力される。

> このディレクトリの証明書 / 鍵は **git 管理外** です (`.gitignore` 済み)。
> `README.md` と `.gitkeep` だけがコミットされます。

---

## 1. なぜ出力するのか

証明書の実体は named volume (`pki`) にあり、コンテナの実行時にしか見えない。
一方で `docker build` は **ビルドコンテキスト (ホスト上のファイル)** しか読めないため、
**イメージのビルドへ証明書を渡すにはホスト側にファイルが必要**になる。

社内標準ベースイメージ (`EAP_BASE_IMAGE`) は、BuildKit の build secret 経由で
「ビルドコンテキスト上の所定のディレクトリに置いた `cacert.crt`」を受け取り、
JVM のトラストストア (JDK 同梱 `cacerts`) と JBoss EAP (Elytron) の
トラストストアへ取り込んでいる。その入力にそのまま使えるファイルがここに出る。

```
pki-init (openssl)
   │  cacert.crt を発行 / 受領物をそのまま配備
   ├──▶ named volume: pki          … 実行時に front/back/mysql/alb/secure-api が参照
   └──▶ compose/pki/export/         … ★ホスト側。docker build へ渡せる
             │
             ├──▶ build secret (id=cacert) ──▶ ベースイメージ / app-front / app-back のビルド
             └──▶ compose/pki/provided/     ──▶ 次回以降その CA を「受領物」として固定
```

---

## 2. 出力されるファイル

| ファイル | 内容 | 主な用途 |
|---|---|---|
| `cacert.crt` | ★唯一のトラストアンカー (受領物 or 自動発行) | **build secret の入力** / `provided/` へ置いて固定 |
| `cacert.key` | その秘密鍵。存在する場合のみ (`PKI_EXPORT_KEY=0` で抑止) | `provided/` へ一緒に置くとパターン A を維持できる |
| `verify-bundle.crt` | サーバ証明書を検証できる CA の集合 | `curl --cacert` などホストからの検証 |
| `trust/*.crt` | front/back のトラストストアへ入る証明書一式 | 複数証明書をまとめて焼き込むビルドの入力 |
| `MANIFEST.txt` | 出力日時 / モード / SHA-256 指紋 / 各ファイルの sha256 | ビルドへ渡した証明書の同一性確認 |

`cacert.crt` は **PEM 1 枚**で、中身の書き換えは一切していない
(受領物を使っている場合は受領物のバイト列そのもの)。

---

## 3. 使い方

### 3-1. イメージのビルドへ build secret で渡す

```bash
docker compose up -d pki-init                     # cacert.crt がここへ出力される
ls compose/pki/export/

# compose のオーバーレイで app-front / app-back のビルドへ渡す
docker compose -f compose.yaml -f compose.build-secret.yaml build app-front app-back
docker compose -f compose.yaml -f compose.build-secret.yaml up -d

# 素の docker build で渡す場合 (ベースイメージのビルドはこの形)
docker build --secret id=cacert,src=compose/pki/export/cacert.crt \
             --build-arg EAP_BASE_IMAGE=... -f front/Dockerfile ./docker
```

取り込まれたことの確認:

```bash
docker compose logs app-front | grep 'truststore\[build\]'
docker compose exec app-front cat /opt/pki/build-import.txt
curl -s http://localhost:8080/tls-probe/truststore | jq -r '.stores[].cacertSha256'
```

### 3-2. そのまま `compose/pki/provided/` へ置いて固定する

出力された `cacert.crt` は **`compose/pki/provided/` へコピーするだけでそのまま使える**
(形式変換・リネームは不要)。次回以降 `pki-init` は `provided` モードになり、
同じ CA を使い続ける = 自動発行した CA を「受領物」として固定できる。

```bash
cp compose/pki/export/cacert.crt compose/pki/provided/cacert.crt
cp compose/pki/export/cacert.key compose/pki/provided/cacert.key   # 鍵も出ていれば
docker compose restart pki-init
docker compose restart secure-api alb mysql app-front app-back
docker compose logs pki-init | grep -E 'MODE:|SHA-256'
```

`./pki-export.sh --to-provided` が上記のコピーを代行する。

> `cacert.key` を**一緒に置くかどうか**で挙動が変わる。
> 置けばパターン A (受領 CA が全サーバ証明書を発行)、置かなければパターン B
> (`local-test-ca` が発行) になる。詳細は
> [`../provided/README.md`](../provided/README.md) を参照。

### 3-3. ベースイメージのビルドコンテキストへ直接出力する

`.env` で出力先そのものをビルドコンテキスト配下へ向けられる。

```dotenv
PKI_EXPORT_DIR=../base-image/secrets
```

`./pki-export.sh --to ../base-image/secrets` でも同じ配置ができる。

---

## 4. 関連する環境変数 (`.env` で設定)

| 変数 | 既定値 | 説明 |
|---|---|---|
| `PKI_EXPORT_DIR` | `./compose/pki/export` | 出力先 (ホストパス)。`pki-init` へ `/export` として read-write で bind mount する |
| `PKI_EXPORT_KEY` | `1` | `cacert.key` も出力するか。`0` で出力しない |
| `PKI_BUILD_SECRET_FILE` | `./compose/pki/export/cacert.crt` | `compose.build-secret.yaml` がビルドへ渡すファイル |

---

## 5. セキュリティ上の注意 (テスト環境専用)

- `cacert.crt` は公開してよい証明書 (公開鍵) だが、**`cacert.key` は CA の秘密鍵**。
  持っている人は任意のサーバ証明書を発行できる。コミット / 共有しないこと。
- 鍵を持ち出したくない場合は `.env` で `PKI_EXPORT_KEY=0` を指定する
  (その場合、出力物を `provided/` へ置くとパターン B になる)。
- `--mount=type=secret` はビルド中だけ tmpfs にマウントされ、イメージのレイヤーにも
  ビルドキャッシュにも残らない。`COPY` で証明書をイメージへ持ち込むのとは異なる。

詳細は [`docs/TLS-SELF-SIGNED-ALB.md`](../../../docs/TLS-SELF-SIGNED-ALB.md) 3 章、
一覧表は [`docs/PKI-CACERT-EXPORT.xlsx`](../../../docs/PKI-CACERT-EXPORT.xlsx) を参照。
