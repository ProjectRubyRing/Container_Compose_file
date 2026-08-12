# 受領済み自己証明書 (cacert.crt) の投入口

すでに発行され、連携されてきた**自己証明書 `cacert.crt`** をここへ置くと、
`pki-init` は CA を新規発行せず、その受領物をそのままトラストアンカーとして
compose 全体へ配ります。

> このディレクトリの証明書 / 鍵は **git 管理外** です (`.gitignore` 済み)。
> `README.md` と `.gitkeep` だけがコミットされます。

---

## 1. 置き方

```
compose/pki/provided/
  cacert.crt   ← ★受領済みの自己証明書 (必須)。PEM / DER どちらでも可
  cacert.key   ← 任意。受領していれば置く (後述)
```

置いたら反映する:

```bash
docker compose up -d pki-init          # 未起動なら
docker compose restart pki-init        # すでに起動している場合
docker compose restart secure-api alb mysql frontend backend
docker compose logs pki-init           # ★どのモードで動いたかを必ず確認する
```

受領した `cacert.crt` を別のものに差し替えた場合、`pki-init` は
入力の SHA-256 が変わったことを自動検知して PKI を作り直します
(`PKI_FORCE_REGENERATE=1` を付ける必要はありません)。

### repo の外に置きたい場合

`.env` でホストパスを指定できます (bind mount 元が切り替わります)。

```dotenv
PKI_PROVIDED_DIR=/c/secure/certs/received
```

### `pki-init` が発行した CA をここへ置いて固定する

受領物が無い場合 `pki-init` は自己署名 CA を自動発行しますが、その `cacert.crt` は
ホストの [`../export/`](../export/README.md) にも出力されます。
**出力された `cacert.crt` はそのままこのディレクトリへ置けます** (変換・リネーム不要)。
置くと次回以降 `provided` モードになり、同じ CA を使い続けられます。

```bash
./pki-export.sh --to-provided        # export/ の cacert.crt (+key) をここへ配置
docker compose restart pki-init secure-api alb mysql frontend backend
```

`cacert.key` も一緒に置けば下表の (A)、`cacert.crt` だけなら (B) になります。

---

## 2. 受領物に秘密鍵があるかどうかで挙動が変わる

`pki-init` は `cacert.key` の有無を自動判定して 2 系統に分かれます。

| | (A) `cacert.crt` + `cacert.key` | (B) `cacert.crt` のみ (鍵なし) |
|---|---|---|
| サーバ証明書の発行元 | **受領 CA** | `local-test-ca` (pki-init が生成) |
| `trust/cacert.crt` | 受領物 | 受領物 (同じ) |
| `ca/verify-bundle.crt` | `cacert.crt` のみ | `cacert.crt` + `local-test-ca.crt` |
| 受領 cacert.crt 単体で HTTPS 検証 | **できる** | できない |
| tls-verifier の全項目 | すべて PASS | 項目 7 (取り込み) は受領物で PASS |

### なぜ (B) では受領 CA でサーバ証明書を発行できないのか

**秘密鍵の無い CA 証明書はトラストアンカーとしてしか使えません。**
証明書への署名には CA の秘密鍵が必須なので、鍵が無い以上、ローカルの
`secure-api` / `alb` / `mysql` が「受領 CA が発行したサーバ証明書」を
提示することは暗号的に不可能です。

そこで役割を分離しています。

```
受領 cacert.crt  → トラストアンカーとして実際に配布・取り込みする対象
                    (front/back の JDK / JBoss トラストストアへ入るのは受領物そのもの)
local-test-ca    → サーバ証明書を発行するためだけのローカル CA
```

これにより「受領物が正しく配布・取り込みされているか」は受領物で検証しつつ、
HTTPS / MySQL / ALB といった他の検証項目はブロックされずに実行できます。

`cacert.key` を後からこのディレクトリへ置けば **自動的に (A) へ昇格**し、
`local-test-ca` は作られなくなります。

### (B) で「受領 cacert.crt 1 枚だけを信頼する」状態にしたい

`.env` で `PKI_TRUST_LOCAL_CA=0` を設定すると `local-test-ca` を
トラストストアへ入れなくなります。この状態では `secure-api` への接続が
PKIX エラーで失敗しますが、それが**期待値**です
(= 受領 CA 発行でないサーバ証明書は弾かれる、という対照実験になります)。

---

## 3. 受領物のチェック内容

`pki-init` は起動時に次を検査してログへ出します
(`docker compose logs pki-init`)。異常でも原則は警告に留め、
「わざと期限切れ証明書を投入して挙動を見る」ような検証も行えるようにしています。

- PEM / DER の判別と PEM への正規化 (`Bag Attributes` などの余計なテキストも除去)
- 自己署名か (`openssl verify -CAfile cacert.crt cacert.crt`)
- `basicConstraints: CA:TRUE` を持つか (無ければ自己署名リーフとして扱う)
- 有効期限切れでないか
- SHA-256 フィンガープリント (差し替え検知にも使う)
- `cacert.key` がある場合、その鍵が `cacert.crt` と対になっているか
  (公開鍵が一致しなければ**起動を中止**する)

---

## 4. 関連する環境変数 (`.env` で設定)

| 変数 | 既定値 | 説明 |
|---|---|---|
| `PKI_PROVIDED_DIR` | `./compose/pki/provided` | 受領物の置き場 (ホストパス) |
| `PKI_MODE` | `auto` | `auto` = `cacert.crt` があれば使う / `provided` = 必須 (無ければ起動失敗) / `generate` = 受領物を無視して自動発行 |
| `PKI_TRUST_LOCAL_CA` | `1` | 鍵なし時に `local-test-ca` をトラストストアへ入れるか |
| `PKI_EXPORT_DIR` | `./compose/pki/export` | 配備した `cacert.crt` の**出力先**。ここへ出たものをこのディレクトリへ置き直せる |

---

## 5. 関連: 出力側 (`../export/`)

| | `provided/` (このディレクトリ) | [`export/`](../export/README.md) |
|---|---|---|
| 向き | **入力** — 受領した `cacert.crt` を投入する | **出力** — 配備した `cacert.crt` を書き出す |
| 誰が置く / 書く | 人 (受領物をコピー) | `pki-init` が自動 |
| 主な使い道 | この CA をトラストアンカーにする | イメージのビルドへ build secret で渡す / `provided/` へ置き直す |

出力された `cacert.crt` を `provided/` へ置く往復ができるので、
「自動発行 → その CA を固定 → ビルドへ焼き込む」という流れがそのまま回ります。

詳細は [`docs/TLS-SELF-SIGNED-ALB.md`](../../../docs/TLS-SELF-SIGNED-ALB.md) を参照。
