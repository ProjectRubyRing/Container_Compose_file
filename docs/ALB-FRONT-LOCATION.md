# frontend 向け ALB の偽装と Location ヘッダ確認 (alb-front)

本番構成では **ブラウザ → ALB は HTTPS、ALB → コンテナ (JBoss EAP) は HTTP** で通信する。
この構成で、JBoss EAP 上のアプリがリダイレクトを返すと **`Location` が `http://...` に
なってしまう**問題がある。`alb-front` サービスは ALB の「HTTPS リスナー → HTTP ターゲット
グループ」の転送を同じ規則で再現し、`Location` が https で返るか
(= ALB の `X-Forwarded-Proto: https` が JBoss EAP に連携されているか) を**区間ごとに**確かめる。

- 偽装の実装: [`compose/alb-front/alb-front.py`](../compose/alb-front/alb-front.py)
- 補足: [`compose/alb-front/README.md`](../compose/alb-front/README.md)
- 確認用 API: 別リポジトリ `dhapp_2` の `GET /api/redirect-check/redirect`
  (`REDIRECT_LOCATION_API.md`)。302 に JBoss EAP の認識を `X-Redirect-Check-*` ヘッダで載せる

## なぜ http になるのか

```
[実 AWS]
  ブラウザ ──HTTPS──▶ ALB :443 (ACM 証明書で TLS 終端)
                        │  X-Forwarded-Proto: https / X-Forwarded-Port: 443 / X-Forwarded-For: <IP>
                        └──HTTP──▶ app-front:8080 (JBoss EAP の http-listener)
                                      sendRedirect("/iwinmichl/xxx")
                                        → Location: <request の scheme>://<Host>/iwinmichl/xxx
```

JBoss EAP (Undertow) は `sendRedirect(相対パス)` を「**request の scheme** + Host + パス」の
絶対 URL にする。ALB → JBoss EAP は HTTP なので、http-listener が `X-Forwarded-Proto` を
読まない (`proxy-address-forwarding=false`、既定) と scheme は `http` のまま
→ `Location: http://...` → ブラウザは http へ遷移する。

`proxy-address-forwarding=true` にすると Undertow は `X-Forwarded-Proto` / `X-Forwarded-For` /
`X-Forwarded-Port` を読み、scheme・接続元・ポートを ALB の手前 (クライアント) 基準に置き換える
→ `Location: https://...`。

## 実 AWS 構成との対応

```
[ローカル compose]
  クライアント ──HTTPS──▶ alb-front :8443 (pki-init 発行の ALB 用証明書で TLS 終端)
   (ホストの curl /           │  X-Forwarded-Proto: https / X-Forwarded-Port: 8443 /
    report のクライアント役)   │  X-Forwarded-For: <IP> / X-Amzn-Trace-Id
                              └──HTTP──▶ frontend:8080 (JBoss EAP)
```

| 実 ALB | alb-front | 等価性 |
|---|---|---|
| HTTPS リスナー (ACM 証明書・`ELBSecurityPolicy-TLS13-1-2-2021-06`) | `:8443`、pki-init の ALB 用 (CA 発行) 証明書、TLS 1.2 / 1.3 | TLS 終端する点は同じ |
| ターゲットグループ (プロトコル HTTP) | `ALB_FRONT_TARGET=http://frontend:8080` | ターゲットへは平文 HTTP |
| `X-Forwarded-For` | クライアント IP を末尾へ追記 | `append` モード (既定) と同じ |
| `X-Forwarded-Proto` / `X-Forwarded-Port` | `https` / リスナーのポート。クライアントの値は上書き | 同じ |
| `X-Amzn-Trace-Id` | 無ければ `Root` を採番、`Root` があれば `Self` を挿入 | 同じ書式 |
| `Host` | クライアントの値をそのまま渡す (`X-Forwarded-Host` は付けない) | 同じ |
| 応答ヘッダ | **`Location` を含めて書き換えない** | 同じ |
| ターゲットに届かない | `503` (未起動) / `502` (接続拒否) / `504` (タイムアウト)、`Server: awselb/2.0` | 同じステータスと本文 |
| リスナーのポート | 443 | 8443 (ホスト公開と同じ番号にして `X-Forwarded-Port` と実際のポートを一致させる) |

既存の `alb` (nginx) は backend / secure-api 向けの L7 ルーティングで、frontend の前段は
持っていない。`alb-front` はそれとは独立したサービスで、既存の経路には影響しない。

## 使い方

```bash
docker compose up -d                       # alb-front も起動する (frontend の起動開始を待つ)

# 1) ホストから https で呼ぶ (Location と JBoss EAP の診断ヘッダ)
curl -sk -D - -o /dev/null https://localhost:8443/iwinmichl/api/redirect-check/redirect
#   Windows の curl (Schannel) で --cacert を使う場合は --ssl-no-revoke も付ける

# 2) 区間ごとのレポート (偽装 ALB のコンテナ内で実行)
docker compose exec alb-front python3 /opt/alb-front/alb-front.py report
docker compose exec alb-front python3 /opt/alb-front/alb-front.py report /iwinmichl/別の API

# 1 と 2 をまとめて実行し、レポートを .alb-front-reports/ へ保存
./verify-alb-front.sh

# ALB のアクセスログ相当 (付与したヘッダ・転送先・ターゲットの応答・Location)
docker compose logs -f alb-front
# 2026-10-10T08:45:38.041+09:00 [alb-front] https:8443 client=172.18.0.1:53884 tls=TLSv1.3
#   "GET /iwinmichl/api/redirect-check/redirect HTTP/1.1" host=localhost:8443
#   -> http://frontend:8080/iwinmichl/api/redirect-check/redirect peer=172.18.0.2:8080
#   target_status=302 status=302 xfp=https xfport=8443 xff=172.18.0.1
#   trace=Root=1-6ac97ca2-… location=https://localhost:8443/iwinmichl/api/redirect-check/landing?… 9ms

# 転送記録 (ALB がターゲットへ送ったヘッダ・ターゲットの応答を JSON で)
curl -s "http://localhost:8581/exchanges?limit=5"
```

`report` の終了コード: `0` = OK / `1` = NG / `2` = 実行不能 / `3` = 判定保留。

## レポートの読み方

`report` は、クライアント役 (偽装 ALB のコンテナ内から `https://localhost:8443`) として
確認対象 API を呼び、次の 6 段を出す。

| 段 | 内容 | 何で確かめるか |
|---|---|---|
| [1] クライアント → 偽装 ALB | **https** で届いたか | TLS バージョン・暗号スイート・サーバ証明書 (検証結果) |
| [2] 偽装 ALB → frontend | **http** で転送したか、何を付けたか | 偽装 ALB の転送記録 (転送先 URL・接続先 IP:ポート・付与ヘッダ・ターゲットの応答) |
| [3] JBoss EAP が受け取った内容 | ヘッダが届き、https と認識したか | dhapp の診断ヘッダ (`X-Forwarded-Proto` の受信値・`request.getScheme()`・実際の通信が平文か・`proxy-address-forwarding`) |
| [4] クライアントへ返った Location | **https** か。ALB が書き換えていないか | 応答の `Location` と転送記録の比較。https なら Location を辿ってリダイレクト先まで確認 |
| [5] 対照実験 | ヘッダ無しなら http に戻るか | 偽装 ALB を通さず frontend:8080 へ直接 (`X-Forwarded-*` なし) |
| [6] JBoss EAP 自身のリダイレクト | アプリだけでなく JBoss EAP の層で直っているか | コンテキストルート (`/iwinmichl` → `/iwinmichl/`) のリダイレクト |

[5] で「ヘッダ無しなら http・ALB 経由なら https」と分かれれば、https が
`X-Forwarded-Proto` から来ていること (アプリが https を決め打ちしていないこと) が分かる。
[6] が http のまま [4] だけ https なら、アプリ側 (Spring の `ForwardedHeaderFilter` など) だけで
補正している状態で、FORM 認証やコンテキストルートなど JBoss EAP 自身のリダイレクトは http に残る。

### OK の例 (`proxy-address-forwarding=true`)

```
[2] 偽装 ALB → frontend (ターゲットグループ HTTP)             … http
  転送先             : http://frontend:8080/iwinmichl/api/redirect-check/redirect  (接続先 172.18.0.2:8080)
  付与・上書きしたヘッダ:
    X-Forwarded-For   : 127.0.0.1
    X-Forwarded-Proto : https
    X-Forwarded-Port  : 8443
    X-Amzn-Trace-Id   : Self=1-6ac97e03-…;Root=1-6ac97e03-…
    Host (透過)       : localhost:8443
  ターゲットの応答   : 302 Found / Location: https://localhost:8443/iwinmichl/api/redirect-check/landing?…

[3] JBoss EAP (frontend) が受け取った内容 (X-Redirect-Check-* 診断ヘッダ)
  受信した X-Forwarded-Proto : https
  実際の通信                 : plain-http (受けたポート 8080)
  request.getScheme()        : https
  proxy-address-forwarding   : default-server/default=true

[4] クライアントへ返った Location
  Location           : https://localhost:8443/iwinmichl/api/redirect-check/landing?…
  ALB での書き換え   : なし (ターゲットの Location をそのまま返却)
  Location を辿る    : GET https://localhost:8443/… → 200 OK (landing: status=OK, scheme=https)

[判定]
  [OK] クライアント → 偽装 ALB は https (TLSv1.3 / TLS_AES_256_GCM_SHA384)
  [OK] 偽装 ALB → frontend は http (接続先 172.18.0.2:8080、TLS なし)
  [OK] 偽装 ALB が X-Forwarded-Proto: https を付与してターゲットへ送信
  [OK] JBoss EAP が X-Forwarded-Proto: https を受信 (ALB の情報が届いている)
  [OK] JBoss EAP は https と認識 (通信は plain-http のまま)
  [OK] Location は https で返却 (偽装 ALB は書き換えていない)
  [OK] Location を https で辿り、リダイレクト先から 200 が返った
  [OK] 対照実験: ヘッダ無しでは http → [4] の https は X-Forwarded-Proto 由来
  [OK] JBoss EAP 自身のリダイレクトも https (JBoss EAP 側で反映されている)

判定結果           : OK (ALB の X-Forwarded-Proto: https が JBoss EAP に連携され、Location は https で返る)
```

### NG の例 (`proxy-address-forwarding=false`、EAP の既定)

```
[3] JBoss EAP (frontend) が受け取った内容 (X-Redirect-Check-* 診断ヘッダ)
  受信した X-Forwarded-Proto : https
  request.getScheme()        : http
  proxy-address-forwarding   : default-server/default=false  ← false のリスナーは X-Forwarded-Proto を読まない

[4] クライアントへ返った Location
  Location           : http://localhost:8443/iwinmichl/api/redirect-check/landing?…

[判定]
  [OK] JBoss EAP が X-Forwarded-Proto: https を受信 (ALB の情報が届いている)
  [NG] JBoss EAP は http と認識している (X-Forwarded-Proto を反映していない)
  [NG] Location が http で返却 (ブラウザは http へ遷移する)
  [--] 対照実験も http ([4] と同じ。X-Forwarded-Proto の有無で結果が変わらない = 反映されていない)
  [NG] JBoss EAP 自身のリダイレクトも http (JBoss EAP が X-Forwarded-Proto を反映していない)

判定結果           : NG (Location が https で返らない / X-Forwarded-Proto が連携されていない)
対処               : ALB からの通信を受ける http-listener で proxy-address-forwarding を有効にする
```

「ヘッダは届いているのに JBoss EAP が反映していない」ことが [3] だけで読み取れる。

## 対処 (JBoss EAP 側)

```
/subsystem=undertow/server=default-server/http-listener=default:write-attribute(name=proxy-address-forwarding,value=true)
reload
```

ローカルの frontend で試す場合 (コンテナを作り直すと元に戻る):

```bash
docker compose exec frontend /opt/server/bin/jboss-cli.sh --connect \
  --command='/subsystem=undertow/server=default-server/http-listener=default:write-attribute(name=proxy-address-forwarding,value=true)'
docker compose exec frontend /opt/server/bin/jboss-cli.sh --connect --command=':reload'
./verify-alb-front.sh      # OK になることを確認
```

恒久対応はベースイメージ / `docker/cli/*.cli` (ビルド時の JBoss CLI) で同じ属性を設定する。

- **8080 へは ALB からしか届かないこと** (セキュリティグループで ALB からの通信だけを許可) が前提。
  直接届く構成で有効にすると、クライアントが `X-Forwarded-*` を偽装できてしまう
- http-listener の `secure=true` は `isSecure()` を true にするだけで scheme は変わらず、
  **Location は直らない**
- アプリ側 (Spring Boot の `server.forward-headers-strategy=framework`) だけで直すと、
  [6] の JBoss EAP 自身のリダイレクトは http のまま残る

## build_and_verify.sh からの確認 (デプロイ後の選択メニュー)

姉妹リポジトリ `Container_Compose_Build_Push_v2_from_Codex/build_and_verify.sh` を
`--keep-container-mode logs` で起動し、サービス選択で `alb-front` を選ぶと、
操作メニューの末尾に **Location ヘッダ確認** が出る。

```bash
cd ../Container_Compose_Build_Push_v2_from_Codex
./build_and_verify.sh --compose-service frontend,alb-front --keep-container-mode logs
```

```
Compose サービス 'alb-front' で実行する操作を選択してください:
  1) ログを表示
  2) bash へ接続 (cd・tree・任意コマンドを実行可能)
  3) healthcheck 設定・実行履歴・通信を確認
  …
  N) Location ヘッダ確認 (偽装 ALB から frontend の API を http で呼び、X-Forwarded-Proto の連携と Location が https で返るかを判定)
  0) Compose サービスの選択へ戻る
選択番号 [0-N]: N
確認する API のパス (Enter で既定: /iwinmichl/api/redirect-check/redirect):
```

偽装 ALB の状態 (起動状態・自身の healthcheck) → 上のレポート全文 →
`Location ヘッダ判定 : OK / NG / 判定保留` の順に出る。同じ内容は `--report-dir` 配下
(無ければ一時ディレクトリ) の `build_and_verify_<日時>_location_header_alb-front.txt` へも出力される。

## よくある食い違い

| 症状 | 原因 | 対処 |
|---|---|---|
| `Location: http://…` (NG) | JBoss EAP の http-listener が `X-Forwarded-Proto` を読んでいない | 上の「対処」。[3] の `proxy-address-forwarding` が `false` になっているはず |
| 判定保留 (`404` など) | 確認対象 API が無い (WAR 未配備・パス違い) | `docker compose logs frontend` でデプロイを確認。dhapp 以外の API は `report <パス>` で指定 |
| 実行不能 (`503`) | frontend が未起動 (名前解決できない) | `docker compose ps frontend`。起動途中なら待つ |
| 実行不能 (`502` / `504`) | frontend が接続を拒否 / 応答が遅い (EAP 起動途中など) | EAP の起動完了を待つ |
| [3] が出ない | 確認対象 API が診断ヘッダを返さない (dhapp 以外の API) | [4] の Location と [5][6] で判断する |
| `Location` のポートが違う | `X-Forwarded-Port` と実際のポートがずれている | ホスト公開ポートを変えるときは `.env` の `ALB_FRONT_HTTPS_PORT` だけを変える (待ち受けと公開が同じ番号になる) |
| ホストの curl が `exit=60` (Windows) | Schannel がテスト用 CA の失効を確認できない | `--ssl-no-revoke` を付ける (`verify-alb-front.sh` は自動で付ける) |
| `alb-front` が起動しない (`8443` 使用中) | ホストの 8443 を別のプロセスが使っている | `.env` に `ALB_FRONT_HTTPS_PORT=9643` などを設定 |
