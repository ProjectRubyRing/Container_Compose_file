# alb-front — frontend 向け ALB (HTTPS リスナー → HTTP ターゲット) の偽装

本番では、ブラウザ → ALB は HTTPS、ALB → ECS タスク (JBoss EAP の `app-front:8080`) は
HTTP で通信する。ALB は TLS を終端し、元の scheme を `X-Forwarded-Proto: https` で
ターゲットへ伝える。JBoss EAP がこのヘッダを反映していないと、アプリのリダイレクト
(`sendRedirect`) の `Location` が `http://...` になる。

この偽装サービスは ALB の「HTTPS リスナー → HTTP ターゲットグループ」の転送を同じ規則で
再現し、`Location` が https で返るかを**区間ごとに**確かめるレポートを出す。

| ファイル | 役割 |
|---|---|
| `alb-front.py` | 偽装本体。HTTPS リスナー + 転送記録 API + CLI (`report` ほか)。標準ライブラリのみ |

## 実 ALB と同じにしている点

- TLS を終端する (TLS 1.2 / 1.3。証明書は pki-init が発行した ALB 用 = ACM 証明書相当)
- ターゲットへは **HTTP** で転送する (ターゲットグループのプロトコル = HTTP)
- 付与・上書きするヘッダ
  - `X-Forwarded-For` … クライアント IP を末尾へ**追記** (`xff_header_processing.mode=append`)
  - `X-Forwarded-Proto` … `https` (クライアントが送った値は捨てて上書き)
  - `X-Forwarded-Port` … リスナーのポート (同上)
  - `X-Amzn-Trace-Id` … 無ければ `Root=1-<epoch hex>-<hex 24>` を採番、`Root` があれば `Self` を挿入
- `Host` はクライアントが送った値をそのまま渡し、`X-Forwarded-Host` は付けない
- ターゲットの応答ヘッダ (**`Location` を含む**) は書き換えない
- ターゲットへ届かないときは ALB 自身が応答する (`Server: awselb/2.0`)
  - 名前解決できない (ターゲット未起動) → `503`、接続拒否 → `502`、
    接続 10 秒 / アイドル 60 秒超過 → `504`

## 実 ALB と違う点 (ローカル都合)

- ターゲットは compose サービス名で 1 つだけ (`ALB_FRONT_TARGET`、既定 `http://frontend:8080`)
- リスナーのポートはホストへ公開するポートと同じ番号 (既定 `8443`)。
  `X-Forwarded-Port` (= JBoss EAP が Location に入れるポート) と、クライアントが実際に使った
  ポートを一致させるため。変えるときは `.env` の `ALB_FRONT_HTTPS_PORT` だけを直す
- ターゲットへの接続は要求ごとに張る / HTTP/2 は扱わない

## 使い方

```bash
# ホストから (Location と JBoss EAP の診断ヘッダ X-Redirect-Check-* を見る)
curl -sk -D - -o /dev/null https://localhost:8443/iwinmichl/api/redirect-check/redirect

# 区間ごとのレポート (クライアント →https→ alb-front →http→ frontend → Location)
docker compose exec alb-front python3 /opt/alb-front/alb-front.py report
docker compose exec alb-front python3 /opt/alb-front/alb-front.py report /iwinmichl/別の API

# 上の 2 つをまとめて実行し、レポートを .alb-front-reports/ へ保存
./verify-alb-front.sh

# ALB のアクセスログ相当 (1 行 / 要求。付与したヘッダ・転送先・Location が出る)
docker compose logs -f alb-front

# 転送記録 (ALB が実際にターゲットへ送ったヘッダと、ターゲットの応答)
curl -s "http://localhost:8581/exchanges?limit=5"
```

`report` の終了コード: `0` = OK / `1` = NG / `2` = 実行不能 / `3` = 判定保留 (リダイレクトが返らない)。

## build_and_verify.sh からの確認

姉妹リポジトリ `Container_Compose_Build_Push_v2_from_Codex/build_and_verify.sh` を
`--keep-container-mode logs` で起動し、サービス選択で `alb-front` を選ぶと、操作メニューに
**Location ヘッダ確認** が出る (確認する API のパスを入力 / Enter で既定)。
詳細は [../../docs/ALB-FRONT-LOCATION.md](../../docs/ALB-FRONT-LOCATION.md) を参照。

## 設定 (環境変数)

| 変数 | 既定 | 内容 |
|---|---|---|
| `ALB_FRONT_HTTPS_PORT` | `8443` | HTTPS リスナーのポート (= `X-Forwarded-Port`) |
| `ALB_FRONT_ADMIN_PORT` | `8081` | 転送記録 API のポート (ホストへは `8581`) |
| `ALB_FRONT_TARGET` | `http://frontend:8080` | ターゲット (HTTP) |
| `ALB_FRONT_TLS_CERT` / `ALB_FRONT_TLS_KEY` | `/pki/alb/ca-issued/…` | リスナーの証明書と鍵 |
| `ALB_FRONT_CA_BUNDLE` | `/pki/ca/verify-bundle.crt` | `report` がリスナーの証明書を検証する CA |
| `ALB_FRONT_CHECK_HOST` | `localhost` | `report` が名乗るホスト名 (Host / SNI。証明書の SAN に含まれること) |
| `ALB_FRONT_CHECK_PATH` | `/iwinmichl/api/redirect-check/redirect` | `report` の既定の API |
| `ALB_FRONT_IDLE_TIMEOUT` / `ALB_FRONT_CONNECT_TIMEOUT` | `60` / `10` | ALB のアイドル / ターゲット接続タイムアウト (秒) |
