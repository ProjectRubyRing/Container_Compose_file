# ALB ターゲットグループのヘルスチェックをローカルで再現する (alb-healthcheck)

ECS/Fargate 構成には**ヘルスチェックが 2 種類**あり、片方が OK でももう片方が NG に
なり得る。この 2 つを混同すると「コンテナは healthy なのに ALB が 503 を返す」
「デプロイが完了しないままタスクが置き換わり続ける」といった状況の原因が追えない。

| | コンテナのヘルスチェック | ALB のヘルスチェック |
|---|---|---|
| 定義場所 | ECS タスク定義の `healthCheck` (= compose の `healthcheck:`) | ALB **ターゲットグループ**のヘルスチェック設定 |
| 実行する場所 | **コンテナの中** (`curl -fs http://127.0.0.1:8080/`) | **コンテナの外** (ALB → ターゲットの IP:ポート) |
| 判定材料 | コマンドの終了コード | **HTTP ステータスコード**が `matcher` に合致するか |
| 状態 | `starting` / `healthy` / `unhealthy` | `initial` / `healthy` / `unhealthy` (+ 理由コード) |
| 失敗時に起きること | ECS がコンテナを停止・置き換え | ALB がルーティングを外し、ECS がタスクを置き換え |
| 名乗る User-Agent | (curl の既定) | `ELB-HealthChecker/2.0` |

前者はこのリポジトリの `compose.yaml` の `healthcheck:` がそのまま担う。
後者を担うのが **`alb-healthcheck` サービス**で、`frontend` / `backend` へ
ALB と同じ要求を外から投げ、ステータスコードと連続成功・連続失敗の回数から
`initial` / `healthy` / `unhealthy` を導出する。

- 偽装の実装: [`compose/alb-healthcheck/healthcheck.py`](../compose/alb-healthcheck/healthcheck.py)
- ヘルスチェック設定 (★差し替え可能★): [`compose/alb-healthcheck/targets.json`](../compose/alb-healthcheck/targets.json)
- 補足: [`compose/alb-healthcheck/README.md`](../compose/alb-healthcheck/README.md)

## 実 AWS 構成との対応

```
[実 AWS]
  ALB ──(リスナー/リスナールール)──→ ターゲットグループ ──→ ECS タスク
   │                                      │                    app-front:8080
   └── ヘルスチェック (30s 間隔) ──────────┘                    app-back:8180
        GET / (User-Agent: ELB-HealthChecker/2.0)
        200 なら成功 → 5 回連続成功で healthy / 2 回連続失敗で unhealthy

[ローカル compose]
  alb (nginx)          … L7 ルーティングだけを担う
  alb-healthcheck      … 上記「ヘルスチェック」だけを担う (この文書の対象)
        GET / → frontend:8080 / backend:8180
```

| 実 AWS | ローカル | 等価性の担保 |
|---|---|---|
| ターゲットグループのヘルスチェック設定 | `targets.json` の各キー | `path` / `matcher` / `interval` / `timeout` / 各 `threshold` を同名・同意味で持つ |
| ヘルスチェック要求 | `GET <path>` + `Host: <target>:<port>` + `User-Agent: ELB-HealthChecker/2.0` + `Connection: close` | 同一 |
| 成功判定 | ステータスコードが `Matcher.HttpCode` に含まれる | 同一 (`200` / `200,301` / `200-299` の書き方も同じ) |
| 状態遷移 | `initial` → 連続成功 `HealthyThresholdCount` 回で `healthy` / 連続失敗 `UnhealthyThresholdCount` 回で `unhealthy` | 同一。途中の 1 回の失敗では状態を変えない |
| 理由コード | `Elb.RegistrationInProgress` / `Elb.InitialHealthChecking` / `Target.ResponseCodeMismatch` / `Target.Timeout` / `Target.FailedHealthChecks` | 同一の文字列と説明文を返す |
| HTTPS ターゲットグループ | ターゲット証明書を検証しない | 同一 (`protocol: HTTPS` 指定時) |
| 登録ターゲット | IP:ポート | compose サービス名:ポート (DNS 名) |
| `draining` / `unused` / `unavailable` | あり | 扱わない (1 タスク構成のため) |

## 使い方

```bash
docker compose up -d                      # alb-healthcheck も一緒に起動する

# ALB がどう判定しているかを 1 行ログで追う (ALB のアクセスログ相当)
docker compose logs -f alb-healthcheck
# 2026-08-13T12:00:00+09:00 [alb-healthcheck] tg=tg-frontend target=frontend:8080 GET /
#   status=200 matcher=200 result=success exit=0 duration=12ms state=healthy
#   streak=success:5/failure:0
# 2026-08-13T12:00:00+09:00 [alb-healthcheck] tg=tg-frontend target=frontend:8080
#   状態遷移 initial -> healthy reason=- description=-

# 状態を JSON で見る (ターゲットグループ名でも compose サービス名でも引ける)
curl -s http://localhost:8580/targets            | python -m json.tool
curl -s http://localhost:8580/targets/frontend   | python -m json.tool

# その場で 1 回だけチェックする (状態機械の連続回数には反映しない)
curl -s http://localhost:8580/targets/backend/check | python -m json.tool

# 人が読む形式のレポート (状態 + その場のチェック結果)
docker compose exec alb-healthcheck \
  python3 /opt/alb-healthcheck/healthcheck.py report --all
```

`report` の終了コード: `0` = OK (healthy かつその場のチェックも成功) /
`1` = NG / `2` = 実行不能 / `3` = 判定保留 (`initial`)。

## ヘルスチェック設定を変えて挙動を確かめる

`compose/alb-healthcheck/targets.json` を書き換えて
`docker compose restart alb-healthcheck` するだけで、ALB のヘルスチェック設定を
変更したときの挙動をそのまま再現できる。よく確認したいのは次の 3 つ。

| 変更 | 確認できること |
|---|---|
| `"path": "/health"` へ変更 | アプリが用意したヘルスチェック用パスで 200 が返るか (ルート `/` が 404 の構成で有効) |
| `"matcher": "200-399"` へ変更 | リダイレクトを成功として扱う ALB 設定にすると `unhealthy` が解消するか |
| `"timeout_seconds"` を小さくする | EAP の応答が遅い区間で `Target.Timeout` になるか (起動直後の再現) |

## build_and_verify.sh からの確認 (デプロイ後の選択メニュー)

姉妹リポジトリ `Container_Compose_Build_Push_v2_from_Codex/build_and_verify.sh` を
`--keep-container-mode logs` で起動すると、デプロイ後にサービスを選ぶ対話メニューが出る。
`alb-healthcheck` が起動していれば、そのターゲット (`frontend` / `backend`) と
偽装サービス自身に **ALB ヘルスチェック確認** が追加される
(表示対象は `targets.json` の定義が唯一の情報源なので、ターゲットを増やせば自動で増える)。

```bash
cd ../Container_Compose_Build_Push_v2_from_Codex
./build_and_verify.sh \
  --compose-service frontend,backend,alb-healthcheck \
  --keep-container-mode logs
```

```
Compose サービス 'frontend' で実行する操作を選択してください:
  1) ログを表示
  2) bash へ接続 (cd・任意コマンドを実行可能)
  3) healthcheck 設定・実行履歴・通信を確認        ← コンテナ内のヘルスチェック
  4) 証明書チェック (トラストストアと HTTPS 接続先を自動検出して確認)
  5) ALB ヘルスチェック確認 (ステータスコード / 成功失敗判定)   ← これ
  0) Compose サービスの選択へ戻る
```

選ぶと次の 3 段が順に出る。

1. **偽装サービスの状態** — `alb-healthcheck` の起動状態・自身の healthcheck・
   再起動回数・状態参照 API の URL。ここが健全でないとターゲットの判定も当てにならない
2. **ALB が導出したターゲットの状態** — `initial` / `healthy` / `unhealthy`、理由コード、
   説明、連続成功・連続失敗回数、定期チェックの履歴 (ステータスコードと成否、戻り値)
3. **その場で実行したヘルスチェック** — 偽装サービスのコンテナから ALB と同じ要求を投げた
   結果。ステータスコード・`matcher` 判定・成功失敗判定・戻り値 (exit)・応答本文

最後に `ALB ヘルスチェック判定 : OK / NG / 判定保留` が出る。
`NG` は診断結果として扱われ、メニューへ戻れる (ヘルパー自体の失敗にはしない)。

## 戻り値 (exit) の読み方

「その場のチェック」の戻り値は、コンテナ内ヘルスチェックが使う `curl -fs` の
終了コードに合わせてある。コンテナ内の healthcheck 結果と同じ尺度で比べられる。

| 戻り値 | 意味 | ALB の理由コード |
|---|---|---|
| `0` | ステータスコードが `matcher` に合致 (成功) | — |
| `22` | ステータスコードが `matcher` に合致しない | `Target.ResponseCodeMismatch` |
| `28` | `timeout_seconds` を超過 | `Target.Timeout` |
| `7` | 接続できない (ポートが listen していない) | `Target.FailedHealthChecks` |
| `6` | 名前解決できない (ターゲットのサービスが未起動) | `Target.FailedHealthChecks` |
| `56` | 応答を解釈できない / TLS ハンドシェイク失敗 | `Target.FailedHealthChecks` |

## よくある食い違い

| 症状 | 原因 | 対処 |
|---|---|---|
| コンテナは `healthy` なのに ALB では `unhealthy` | コンテナ内 `curl -fs http://127.0.0.1:8080/` は通るが、ALB の `path` / `matcher` が実際の応答と合っていない | `targets.json` の `path` / `matcher` を実際の応答に合わせる |
| いつまでも `initial` のまま | `healthy_threshold_count` × `interval_seconds` の時間が経っていない (既定なら最短 150 秒) | 待つ。急ぐ場合は `interval_seconds` を短くする |
| `unhealthy` が解消しない | 復帰にも `healthy_threshold_count` 回の**連続成功**が必要 | ログの `streak=success:n/failure:m` で連続回数を見る |
| `Target.Timeout` が出続ける | EAP の起動途中 (コンテナ側 `start_period` 相当の区間)。ALB には `start_period` に相当する設定がない | 起動完了まで待つ。本番では ECS サービスの health check grace period で吸収する |
