# 性能試験 (Apache JMeter) — コンテナ実行と設定項目の完全ガイド

このリポジトリの compose 構成に追加した `jmeter` サービスの使い方と、
**性能試験の各設定項目の意味・推奨値・外すとどうなるか**をまとめる。

- 実行コンテナ: [`compose/jmeter/`](../compose/jmeter/) (Dockerfile / jmeter-run.sh / user.properties / targets.json)
- 一覧表 (Excel): [`docs/JMETER-SETTINGS.xlsx`](JMETER-SETTINGS.xlsx) — 本書の表を 14 シートにしたもの
- 生成スクリプト: [`docs/tools/gen-jmeter-settings-xlsx.py`](tools/gen-jmeter-settings-xlsx.py)

> 想定バージョンは **Apache JMeter 5.6.3 / Java 21 (Temurin JRE)**。
> `.env` の `JMETER_VERSION` でイメージのバージョンを変えられる。
> **手元の GUI と同じバージョンにそろえること** (新しい版で保存した .jmx は古い GUI で開けないことがある)。

---

## 目次

1. [全体像](#1-全体像)
2. [3 ステップで動かす](#2-3-ステップで動かす)
3. [コマンドと環境変数](#3-コマンドと環境変数)
4. [結果ファイルと GUI での見かた](#4-結果ファイルと-gui-での見かた)
5. [性能試験の設計 — 種類と負荷モデル](#5-性能試験の設計--種類と負荷モデル)
6. [設定項目の詳細](#6-設定項目の詳細)
   - [6.1 スレッドグループ](#61-スレッドグループ-最重要)
   - [6.2 タイマー (ThinkTime / 流量制御)](#62-タイマー-thinktime--流量制御)
   - [6.3 HTTP リクエストと接続設定](#63-http-リクエストと接続設定)
   - [6.4 コンフィグ要素](#64-コンフィグ要素-cookie--cache--dns--csv)
   - [6.5 アサーション](#65-アサーション)
   - [6.6 コントローラ](#66-コントローラ)
   - [6.7 リスナー](#67-リスナー-非-gui-実行では原則使わない)
   - [6.8 JMeter プロパティ (user.properties)](#68-jmeter-プロパティ-userproperties)
   - [6.9 JVM (ヒープ / GC)](#69-jvm-ヒープ--gc)
   - [6.10 結果 (jtl) に保存する項目](#610-結果-jtl-に保存する項目)
   - [6.11 HTML ダッシュボード](#611-html-ダッシュボード)
7. [結果の読み方と合否基準](#7-結果の読み方と合否基準)
8. [この compose 構成に固有の注意](#8-この-compose-構成に固有の注意)
9. [トラブルシューティング](#9-トラブルシューティング)
10. [CI から回す](#10-ci-から回す)
11. [実 AWS (ECS) へ持っていくときの差分](#11-実-aws-ecs-へ持っていくときの差分)

---

## 1. 全体像

```
  手元 (ホスト)                           compose ネットワークの中
  ─────────────                          ─────────────────────────
  JMeter GUI
    │ ①テスト計画を作る
    ▼
  compose/jmeter/test-plans/my-plan.jmx ──┐
  compose/jmeter/targets.json  (投げ先)   │  ②読み取り専用でマウント
  compose/jmeter/user.properties (設定)   │
                                          ▼
                                    ┌───────────────┐   ③HTTP 負荷
                                    │ jmeter        │ ─────────────▶ frontend  (既定)
                                    │ (非 GUI 実行) │                backend
                                    └───────┬───────┘                alb / alb-https
                                            │ ④結果を書き出す        secure-api
  compose/jmeter/results/<run>/  ◀──────────┘
    ├ result.jtl          ─── ⑤JMeter GUI のリスナーで開く
    ├ report/index.html   ─── ⑤ブラウザで開く
    ├ jmeter.log / summary.log / summary-stats.txt
    ├ run-info.txt  (実行条件)
    └ plan.jmx      (実行した計画のコピー)
```

**GUI は「計画を作る」「結果を見る」ためだけに使い、走らせるのはコンテナ側**というのが
この構成の要点。JMeter 公式も、GUI 実行は描画とリスナー保持でリソースを食うため
試験本番では使うなとしている。GUI で負荷をかけると、詰まったのがアプリなのか
JMeter 自身なのか区別できなくなる。

### なぜ compose の中で動かすのか

| | ホストの JMeter から `localhost:8080` を叩く | この `jmeter` コンテナから叩く |
| --- | --- | --- |
| 経路 | ホスト → ポートフォワード → コンテナ | コンテナ → コンテナ (実 ECS と同じサービス間通信) |
| 測る対象に入る余計な要素 | Docker Desktop のポートフォワード (Windows/macOS では無視できない overhead) | なし |
| ALB / HTTPS 経路 | ポート公開したものしか叩けない | `alb`, `secure-api` など内部だけのサービスも叩ける |
| 自己証明書 | ホスト側にも CA の取り込みが必要 | `pki` ボリュームから自動で取り込む |
| 再現性 | ホストの JMeter/Java のバージョンに依存 | イメージで固定 |

---

## 2. 3 ステップで動かす

```bash
# 1) GUI で作った .jmx を置く
cp ~/work/my-plan.jmx compose/jmeter/test-plans/

# 2) 実行 (投げ先の既定は frontend)
docker compose --profile loadtest run --rm jmeter run my-plan.jmx

# 3) 結果
#    compose/jmeter/results/<日時>_<計画名>_<対象>/result.jtl        → JMeter GUI で開く
#    compose/jmeter/results/<日時>_<計画名>_<対象>/report/index.html → ブラウザで開く
```

初回は JMeter のイメージをビルドする (Apache 配布の tgz を SHA-512 検証して展開):

```bash
docker compose --profile loadtest build jmeter
```

同梱サンプルだけで試すなら計画名も省略できる:

```bash
# 何も置いていなければ sample-frontend.jmx が使われる
docker compose --profile loadtest run --rm jmeter run
```

**EAP のベースイメージが無くても配管だけは試せる。** `svf-mock` (WireMock) を対象にすると、
frontend / backend を起動せずに「実行 → jtl → HTML レポート」の流れを確認できる:

```bash
docker compose up -d svf-mock
docker compose --profile loadtest run --rm -e JMETER_TARGET=svf-mock \
  -e JMETER_DURATION=30 jmeter run
```

---

## 3. コマンドと環境変数

### 3.1 サブコマンド

| コマンド | 内容 |
| --- | --- |
| `run [PLAN.jmx] [--target NAME] [--name RUNID] [-- <jmeter 引数>]` | 実行 |
| `list` | `test-plans/` にある .jmx の一覧 |
| `targets` | 投げ先の一覧 (`targets.json`) |
| `doctor` | 自己診断 + 全対象への到達確認 |
| `report <結果ディレクトリ>` | 既存 jtl から HTML ダッシュボードを作り直す |
| `clean [--days N \| --all]` | 古い結果の削除 |
| `version` | JMeter / Java のバージョン |
| `exec <引数...>` | 素の `jmeter` をそのまま実行 |

`--` の後ろに書いたものは JMeter へそのまま渡る:

```bash
docker compose --profile loadtest run --rm jmeter run my-plan.jmx -- -Jsummariser.interval=10 -LDEBUG
```

### 3.2 環境変数 (compose.yaml の `jmeter:` / `.env` / `-e`)

| 環境変数 | 既定 | 渡る先 (JMeter プロパティ) | 意味 |
| --- | --- | --- | --- |
| `JMETER_TARGET` | `frontend` | `target.protocol/host/port/path` | 投げ先 (`targets.json` のキー) |
| `JMETER_PLAN` | (空) | — | 実行する .jmx。引数指定が優先 |
| `JMETER_THREADS` | `10` | `threads` | 同時実行ユーザ数 |
| `JMETER_RAMPUP` | `10` | `rampup` | 全スレッドが立ち上がるまでの秒数 |
| `JMETER_DURATION` | `300` | `duration` | 試験時間 (秒) |
| `JMETER_LOOPS` | `-1` | `loops` | ループ回数 (-1 = 時間で終わるまで) |
| `JMETER_STARTUP_DELAY` | (空) | `startup.delay` | 開始遅延 (秒) |
| `JMETER_THINK_TIME_BASE` | `500` | `think.time.base` | 操作間の待ち (ms) 固定部分 |
| `JMETER_THINK_TIME_RANGE` | `1000` | `think.time.range` | 同 ランダム幅 (ms) |
| `JMETER_CONNECT_TIMEOUT` | `5000` | `connect.timeout` | 接続タイムアウト (ms) |
| `JMETER_RESPONSE_TIMEOUT` | `30000` | `response.timeout` | 応答タイムアウト (ms) |
| `JMETER_THROUGHPUT_PER_MIN` | (空) | `throughput.per.min` | 流量固定タイマー用 (件/分) |
| `JMETER_RESULTS_FORMAT` | `csv` | `jmeter.save.saveservice.output_format` | 結果形式 |
| `JMETER_SAVE_RESPONSE_DATA` | `false` | `jmeter.save.saveservice.response_data` | 応答本文を残すか |
| `JMETER_GENERATE_REPORT` | `true` | (`-e -o`) | HTML ダッシュボードを作るか |
| `JMETER_MAX_ERROR_RATE` | (空) | — | エラー率の上限 (%)。超えると終了コード 2 |
| `JMETER_HEAP` | `-Xms1g -Xmx1g -XX:MaxMetaspaceSize=256m` | (`HEAP`) | 負荷生成側の JVM ヒープ |
| `JMETER_PROPS` | (空) | 任意 | `"key=value key2=value2"` を `-J` で追加 |
| `JMETER_PRECHECK` | `true` | — | 開始前の到達確認をするか |
| `JMETER_RUN_NAME` | (空) | — | 結果ディレクトリ名を固定する |

`.env` に書けば常用の既定値にできる (`.env.example` にひな形あり)。

### 3.3 投げ先 (`compose/jmeter/targets.json`)

| 名前 | 宛先 | 用途 |
| --- | --- | --- |
| `frontend` | `http://frontend:8080/` | **既定**。ECS の app-front 相当 |
| `backend` | `http://backend:8180/` | app-back (port-offset 100) |
| `alb` | `http://alb:80/` | ALB (nginx) のリスナールール込みの経路 |
| `alb-https` | `https://alb:443/secure/v1/ping` | HTTPS リスナー (TLS 込みの負荷) |
| `secure-api` | `https://secure-api:8443/api/v1/ping` | HTTPS 専用の外部 API 相当 |
| `svf-mock` | `http://svf-mock:8080/__admin/health` | EAP 不要で配管確認に使える |
| `alb-healthcheck` | `http://alb-healthcheck:8580/targets` | 負荷中の health 状態参照 |

HTTPS の対象を選ぶと、`jmeter-run` が `pki` ボリュームの `/mnt/pki/trust/*.crt`
(自己証明書 `cacert.crt` を含む) を `keytool` で PKCS12 トラストストアに固め、
`-Djavax.net.ssl.trustStore` で JVM へ渡す。front/back の entrypoint と同じ考え方で、
これが無いと `PKIX path building failed` になる (docs/TLS-SELF-SIGNED-ALB.md)。

---

## 4. 結果ファイルと GUI での見かた

1 回の実行につき 1 ディレクトリ:

| ファイル | 中身 | 見かた |
| --- | --- | --- |
| `result.jtl` | 全サンプルの生データ | **JMeter GUI のリスナーで開く** |
| `report/index.html` | HTML ダッシュボード | ブラウザで開く |
| `report/statistics.json` | ダッシュボードの元数値 | 機械処理・CI の判定に使える |
| `jmeter.log` | JMeter 自身のログ | エラーの一次調査 |
| `summary.log` | 実行中の標準出力 (進捗) | 走行中の様子 |
| `summary-stats.txt` | 一次集計 | 合否の当たり |
| `run-info.txt` | 実行条件 | 再現・比較のため |
| `plan.jmx` | 実行した計画のコピー | 「どの計画で出た結果か」の証跡 |

### GUI で jtl を開く手順

1. JMeter GUI を起動 → 適当なテスト計画を開く (空でもよい)
2. テスト計画を右クリック → 「追加」→「リスナー」→ 見たいものを選ぶ
3. リスナーの **「結果のファイル名」** 欄で `result.jtl` を指定する (参照ボタン)
4. 読み込みが終わると、そのリスナーの形式で表示される

| リスナー | 何が分かるか | CSV 形式で足りるか |
| --- | --- | --- |
| 統計レポート (Summary Report) | ラベル別のサンプル数・平均・最小最大・エラー率・スループット | ○ |
| 集計レポート (Aggregate Report) | 上記 + 中央値・90/95/99 パーセンタイル | ○ |
| 結果をツリーで表示 (View Results Tree) | 1 件ずつの要求/応答 | △ 本文は XML 形式でのみ |
| 応答時間の推移 (Response Time Graph) | 応答時間の時系列 | ○ |
| アクティブスレッド数 | 負荷レベルの推移 | ○ (`thread_counts=true` が必要) |

> 既定の CSV 形式は **応答本文を保存していない**。本文まで見たいときは
> `-e JMETER_RESULTS_FORMAT=xml -e JMETER_SAVE_RESPONSE_DATA=true` で実行し直す。
> XML はファイルが数十倍になり、HTML ダッシュボードは作れない (入力は CSV のみ)。

---

## 5. 性能試験の設計 — 種類と負荷モデル

### 5.1 試験の種類と推奨パラメータ

| 種類 | 目的 | スレッド数 | ramp-up | 試験時間 | ThinkTime | 合否の見どころ |
| --- | --- | --- | --- | --- | --- | --- |
| **スモーク** | 計画とシナリオが壊れていないかの確認 | 1〜5 | 5 秒 | 1〜2 分 | 通常どおり | エラー 0 件。数値は見ない |
| **ロード (負荷)** | 想定ピークで SLA を満たすか | 想定同時ユーザ数 | スレッド数と同じ秒数以上 | 15〜30 分 (定常 10 分以上) | 実態どおり (1〜5 秒) | 95%ile 応答、エラー率、スループット |
| **ストレス** | 限界点と、そこでの壊れ方 | 想定の 2〜5 倍まで段階的に | 段階ごとに 1〜2 分 | 30〜60 分 | 短め (0.5〜1 秒) | どこで応答が折れるか、回復するか |
| **スパイク** | 瞬間的な殺到への耐性 | 平常 → 一気に 5〜10 倍 | **0〜10 秒** (わざと急峻に) | 10〜20 分 | 短め | エラー急増後に平常へ戻るか |
| **耐久 (ソーク)** | メモリリーク・接続リーク | 想定の 60〜80% | 緩やか | **2〜24 時間** | 実態どおり | 応答の右肩上がり、ヒープ、接続数 |
| **ブレークポイント** | 上限値の把握 | 段階的に増やし続ける | 段階ごと | 限界まで | 0〜短め | エラー率が跳ねる点 |

この compose 構成 (ローカル 1 台) で意味があるのは主に **スモーク / ロード / 耐久の短縮版**。
ストレス・ブレークポイントは、負荷生成側 (JMeter) とアプリが同じマシンの CPU を
奪い合うため、限界値そのものは本番の参考にならない (**傾向の比較には使える**)。

### 5.2 必要なスレッド数を逆算する (Little の法則)

```
  同時実行ユーザ数 (スレッド数) = 目標スループット [req/s] × (平均応答時間 [s] + ThinkTime [s])
```

例: 目標 50 req/s、平均応答 0.2 秒、ThinkTime 3 秒
→ 50 × (0.2 + 3.0) = **160 スレッド**

逆に「スレッド数を決め打ちしたときに出る流量」は:

```
  スループット [req/s] = スレッド数 ÷ (平均応答時間 + ThinkTime)
```

**ThinkTime を 0 にすると同じスレッド数で桁違いの流量になる。**
「100 ユーザ」を再現したいのか「100 並列の全力」を測りたいのかを必ず区別すること。
前者ならタイマーは必須、後者なら ThinkTime 0 + `Constant Throughput Timer` 無効。

### 5.3 ramp-up の決め方

| 状況 | 推奨 ramp-up |
| --- | --- |
| 通常のロード試験 | **スレッド数と同じ秒数以上** (= 毎秒 1 ユーザずつ増やす) |
| 起動が重いアプリ (JIT / 接続プール / キャッシュ) | スレッド数 × 2〜3 秒 |
| スパイク試験 | 0〜10 秒 (わざと急峻にする) |
| 耐久試験 | 5〜10 分かけて緩やかに |

ramp-up が短すぎると、測っているのが「定常状態の性能」ではなく
「同時接続の瞬間的な殺到」になる。逆に長すぎると、定常状態の時間が足りなくなる。
**試験時間 ≧ ramp-up + 定常 10 分** を目安にする。

### 5.4 ウォームアップを結果から外す

JVM (EAP) は JIT コンパイルと接続プールの温まりで、最初の数分が遅い。
方法は 2 つ:

1. **捨て試験を先に流す**: 短いスモークを 1 回流してから本番試験を実行する (推奨)
2. **レポート側で切り捨てる**: `-Jjmeter.reportgenerator.start_date=<epoch ms>` で
   集計開始時刻を指定する (`run-info.txt` の `started_at` から逆算)

---

## 6. 設定項目の詳細

### 6.1 スレッドグループ (最重要)

| 設定 | JMeter 上の名前 | 意味 | 既定 (サンプル) | 推奨 | 外す/誤るとどうなるか |
| --- | --- | --- | --- | --- | --- |
| スレッド数 | `ThreadGroup.num_threads` | 同時実行ユーザ数 | `${__P(threads,10)}` | 5.2 で逆算。1 コンテナ 200〜300 が上限目安 | 多すぎると JMeter 側が CPU/ヒープで詰まり、アプリの性能を測れない |
| Ramp-Up 期間 | `ThreadGroup.ramp_time` | 全スレッド起動までの秒数 | `${__P(rampup,10)}` | スレッド数と同じ秒数以上 | 0 にすると全員同時接続。接続確立の殺到を測ることになる |
| ループ回数 | `LoopController.loops` | 1 スレッドあたりの繰り返し | `-1` (無限) | 時間で終える試験は `-1` | 有限回だと ramp-up 中に終わるスレッドが出て、負荷が一定にならない |
| スケジューラ | `ThreadGroup.scheduler` | 継続時間で終了させる | `true` | 時間ベースの試験では必須 | false だとループ回数依存になり、試験時間が読めない |
| 継続時間 | `ThreadGroup.duration` | 試験時間 (秒) | `${__P(duration,300)}` | ramp-up + 定常 10 分以上 | 短いとウォームアップだけを測ることになる |
| 起動遅延 | `ThreadGroup.delay` | 開始までの待ち (秒) | `0` | 複数スレッドグループをずらすときに使う | — |
| サンプラーエラー後の動作 | `ThreadGroup.on_sample_error` | エラー時の挙動 | `continue` | **continue** (性能試験は落ちても流し続けて全体像を見る) | `stoptest` にすると 1 件のエラーで試験が終わり、傾向が取れない |
| 反復ごとに同じユーザ | `same_user_on_next_iteration` | 繰り返しで同一ユーザ扱いにするか | `false` | 毎回新規ログインを模すなら false、ログイン後の操作を繰り返すなら true | true のままだとセッション再利用で認証処理の負荷が落ちる |

**複数のスレッドグループ**を並べると業務ごとの比率を再現できる
(例: 参照 70% / 更新 20% / 帳票 10% → スレッド数を 70/20/10 にする)。
`TestPlan.serialize_threadgroups` を true にすると順番に実行される (段階試験向け)。

### 6.2 タイマー (ThinkTime / 流量制御)

タイマーは**同じスコープ内の全サンプラーの前**に適用される (置いた位置ではなくスコープで決まる)。

| タイマー | 用途 | 推奨値 | 注意 |
| --- | --- | --- | --- |
| **一定のタイマー** (Constant Timer) | 固定の待ち | API 連携の再現: 100〜500 ms | 全スレッドが同じ周期で揃い、波ができやすい |
| **均一乱数タイマー** (Uniform Random Timer) | 人の操作間隔 | 固定 1000 + 幅 2000 ms (画面遷移) | **画面系はこれが基本**。幅 0 は避ける |
| **ガウス乱数タイマー** | 正規分布の待ち | 平均 3000 / 偏差 1000 ms | 実測値が正規分布に近いとき |
| **ポアソン乱数タイマー** | 到着間隔が独立なとき | ラムダを実測から | 理論寄り。使う場面は限定的 |
| **一定スループットタイマー** (Constant Throughput Timer) | 流量を件/分で固定 | 実測 TPS を再現するとき | **上限を絞る方向にしか効かない**。スレッド数が足りなければ目標に届かない |
| **Precise Throughput Timer** | 上記の精度向上版 | 高精度な流量制御が要るとき | 5.0 以降。設定項目が多い |
| **同期タイマー** (Synchronizing Timer) | N 人を溜めて同時発射 | スパイク試験 | 溜まりきらないとタイムアウトまで止まる。人数はスレッド数以下に |

サンプル計画の既定は `THINK_TIME_BASE=500ms` + `RANGE=1000ms` (= 0.5〜1.5 秒)。
実業務を模すなら 1000 + 2000〜4000 程度へ上げる。

**一定スループットタイマーの計算モード** (`calcMode`):

| 値 | 意味 | 使いどころ |
| --- | --- | --- |
| 0 | このスレッドのみ | 1 スレッドあたりの流量を決めたい |
| 1 | 現在のスレッドグループの全スレッド | グループ合計で流量を決める |
| **2** | 同上 (共有) | **既定の推奨**。グループ合計を全スレッドで按分 |
| 3 | 全スレッド | 複数グループ合計 |
| 4 | 同上 (共有) | 複数グループ合計を按分 |

### 6.3 HTTP リクエストと接続設定

| 設定 | 意味 | 推奨 | 外すとどうなるか |
| --- | --- | --- | --- |
| 実装 (`implementation`) | HTTP クライアント実装 | **HttpClient4** | Java 実装は接続プール・Keep-Alive の挙動が異なり、実クライアントとずれる |
| Keep-Alive (`use_keepalive`) | 接続を使い回すか | 実クライアントに合わせる (通常 true) | false にすると毎回 TCP+TLS。ローカルポートを食い潰し、OS が先に詰まる |
| 接続タイムアウト (`connect_timeout`) | TCP 接続確立の上限 (ms) | **3000〜10000** | 0 (無制限) だと詰まりが「遅い応答」に化けて原因が見えない |
| 応答タイムアウト (`response_timeout`) | 応答受信の上限 (ms) | **SLA の 2〜3 倍** (例 30000) | 無制限だと全スレッドが待ちに入り、スループットが 0 のまま試験が終わる |
| リダイレクトの追跡 (`follow_redirects`) | 302 を追うか | true (ブラウザの実態) | `auto_redirects` との併用は不可。auto は 1 サンプルに畳み込まれる |
| 埋め込みリソース (`image_parser`) | 画像/CSS/JS も取得 | 画面の実態を測るなら true | true にすると 1 サンプルの中で数十リクエストが走り、結果の粒度が粗くなる |
| 並列ダウンロード (`concurrentDwn` / `concurrentPool`) | 埋め込みリソースの並列数 | ブラウザに合わせ 6 | 上げすぎると負荷生成側のスレッドが増える |
| Content encoding | 送信の文字コード | **UTF-8** | 日本語が化ける。サーバ側の解釈に依存する |
| Raw ボディ (`postBodyRaw`) | JSON などを生で送る | API 試験では true | false だとフォームパラメータとして送られる |

**HTTP リクエスト初期値** (HTTP Request Defaults) にホスト・ポート・タイムアウトを
まとめておくと、サンプラー側は path とメソッドだけになる。
投げ先の差し替え (`${__P(target.host,...)}`) はここ 1 か所で効く。

### 6.4 コンフィグ要素 (Cookie / Cache / DNS / CSV)

| 要素 | 役割 | 推奨設定 | 外すとどうなるか |
| --- | --- | --- | --- |
| **HTTP クッキーマネージャ** | セッション Cookie の保持 | `policy=standard`、`clearEachIteration=true` | 無いと毎リクエスト新規セッション。EAP 側のセッション生成負荷が実態より跳ね上がる |
| **HTTP キャッシュマネージャ** | ブラウザキャッシュの再現 | `clearEachIteration=true`、`maxSize=5000`、`useExpires=true` | 画面試験で無いと毎回全リソースを取りに行き、実態より重く出る |
| **HTTP ヘッダマネージャ** | 共通ヘッダ | `User-Agent` を試験用に固定、`Accept-Encoding: gzip` | UA を固定しないと、アプリのアクセスログから試験分を切り出せない |
| **DNS キャッシュマネージャ** | 名前解決をスレッドごとに | ALB の複数 IP へ分散させたいとき | 無いと JVM が 1 つの IP をキャッシュし続け、分散が効かない |
| **CSV データセット設定** | 外部データの供給 | 下表 | 同じ値を投げ続けるとアプリ側キャッシュに助けられ、性能を過大評価する |
| **ユーザー定義変数** | 定数の集約 | 投げ先・閾値をここに | ばらまくと差し替え漏れが起きる |
| **JDBC 接続設定** | DB へ直接負荷 | アプリ経由で測るのが原則 | — |

**CSV データセット設定の項目**:

| 項目 | 意味 | 推奨 |
| --- | --- | --- |
| `filename` | 読むファイル | コンテナ内パス (`/test-plans/data/xxx.csv`)。`${__P(csv.file,...)}` で差し替え可能に |
| `variableNames` | 列に対応する変数名 | ヘッダ行と同じ順で明示する |
| `ignoreFirstLine` | ヘッダ行を飛ばす | ヘッダがあるなら true |
| `delimiter` | 区切り | `,` (タブは `\t`) |
| `fileEncoding` | 文字コード | **UTF-8** |
| `recycle` | 末尾まで来たら先頭へ戻る | 時間ベースの試験では **true** |
| `stopThread` | 使い切ったらスレッド停止 | データを 1 回ずつしか使えない試験 (会員登録など) では true (+ `recycle=false`) |
| `shareMode` | 共有範囲 | **shareMode.all** (全スレッドで 1 ファイル = 行の重複なし)。スレッドごとに同じデータを配りたいなら `shareMode.thread` |

### 6.5 アサーション

**性能試験でもアサーションは必須**。無いと「200 を返すエラー画面」や「空の応答」が
成功として集計され、「速いが壊れている」状態を見逃す。ただし判定はサンプルごとに
CPU を使うので、必要最小限にする。

| アサーション | 用途 | コスト | 推奨 |
| --- | --- | --- | --- |
| 応答アサーション (応答コード / equals) | ステータス判定 | 低 | **必ず入れる** |
| 応答アサーション (本文 / substring) | 画面の要素確認 | 中 | 主要画面に 1 つ |
| 応答アサーション (本文 / 正規表現) | 複雑な判定 | **高** | 大規模試験では避ける |
| 継続時間アサーション | SLA 超過をエラーにする | 低 | SLA 違反率をそのまま出したいとき |
| サイズアサーション | 空応答の検出 | 低 | 帳票・ファイル取得の試験で有効 |
| JSON アサーション | API の戻り値 | 中 | API 試験で 1 つまで |

`Assertion.test_type` の値: 1=matches(正規表現全体) / 2=contains(正規表現部分) /
8=equals(完全一致) / 16=substring(部分一致・正規表現なし)。
**16 (substring) は正規表現を使わないぶん速い**ので、単純な文字列確認はこちらを使う。

### 6.6 コントローラ

| コントローラ | 用途 | 注意 |
| --- | --- | --- |
| **トランザクションコントローラ** | 業務単位 (1 画面 / 1 業務) でまとめる | `parent=false` 推奨 (後述) |
| ループコントローラ | 部分的な繰り返し | スレッドグループのループとは別物 |
| **スループットコントローラ** | 業務比率の再現 (参照 70% / 更新 30% 等) | `percent executions` + `per user` で安定する |
| インターリーブ / ランダムコントローラ | 交互・ランダムに 1 つ選ぶ | シナリオのばらつきを作る |
| If コントローラ | 条件分岐 | 条件式の評価コストに注意。`__jexl3` より変数比較が速い |
| Once Only コントローラ | ログインなど初回だけ | スレッドごとに 1 回 |
| **Runtime コントローラ** | 指定秒だけ回す | 段階試験の組み立てに使える |

> **トランザクションコントローラの `parent`**
> `parent=true` にすると配下のサンプルを内包した親サンプルになり、
> 非 GUI 実行の進捗表示 (summariser) が **1 スレッドあたり 1 件しか数えなくなる**
> (本構成で実測: 7 スレッドの試験で summariser が 7 件と表示、jtl は 1,287 行)。
> 走行中の進捗が読めなくなるため、同梱サンプルは **`parent=false`** にしてある。
> false でも HTML レポートには業務単位の行 (`TR01 ...`) が出るので、
> 「業務単位で読む」という目的は達成できる。

### 6.7 リスナー (非 GUI 実行では原則使わない)

| リスナー | 試験中に置いてよいか |
| --- | --- |
| 結果をツリーで表示 / 統計レポート / 集計レポート / グラフ系 | **置かない** (メモリと CPU を食う)。結果は後から jtl を開いて見る |
| シンプルデータライタ | 置いてもよいが `-l` と二重出力になる。通常は不要 |
| Backend Listener (InfluxDB / Graphite) | 走行中に外部へ送りたいときのみ。送信自体が負荷になる点に注意 |

`jmeter-run` は `-l <結果ディレクトリ>/result.jtl` を必ず指定するので、
**計画側にリスナーを 1 つも置かなくても結果は残る**。

### 6.8 JMeter プロパティ (`compose/jmeter/user.properties`)

| プロパティ | 既定 (本構成) | 意味 / 推奨 |
| --- | --- | --- |
| `jmeter.httpsampler` | `HttpClient4` | HTTP 実装。変更しない |
| `httpclient4.idletimeout` | `20000` | 接続プールに保持する時間 (ms)。**サーバの keepalive_timeout より短くする** (nginx 75 秒 / Undertow 60 秒) |
| `httpclient4.validate_after_inactivity` | `1700` | この時間アイドルした接続は再検証。`NoHttpResponseException` 対策の要 |
| `httpclient4.time_to_live` | `60000` | 接続の最大生存時間。ALB のスケールイン時に古い接続を掴み続けない |
| `httpclient4.retrycount` | `0` | **性能試験では 0**。リトライすると失敗が成功として記録され、結果が実態より良く出る |
| `httpclient4.request_sent_retry_enabled` | `false` | POST の再送を禁止 (二重登録防止) |
| `httpclient.reset_state_on_thread_group_iteration` | `true` | 繰り返しごとに接続・認証状態を初期化 (= 新規ユーザ) |
| `http.default.keepalive` | `true` | Keep-Alive の既定 |
| `https.default.protocol` / `https.socket.protocols` | `TLSv1.2` / `TLSv1.2 TLSv1.3` | 実環境 (ALB) に合わせる |
| `https.use.cached.ssl.context` | `true` | TLS セッション再開。false にすると毎回フルハンドシェイク (TLS 負荷を最大に見たいとき) |
| `summariser.interval` | `30` | 進捗表示の間隔 (秒)。6 未満は無視。長時間試験は 60 |
| `jmeterengine.force.system.exit` | `true` | 試験後に JVM を確実に終了 (CI で必須) |
| `jmeterengine.threadstop.wait` | `5000` | 停止要求後の待ち (ms)。応答の遅い相手なら長めに |
| `aggregate_rpt_pct1/2/3` | `90/95/99` | レポートに出すパーセンタイル |

`.jmx` 側で変えたいときは `-J` が優先される:

```bash
docker compose --profile loadtest run --rm jmeter run my-plan.jmx -- -Jhttpclient4.retrycount=1
```

### 6.9 JVM (ヒープ / GC)

| 項目 | 目安 | 備考 |
| --- | --- | --- |
| `-Xms` / `-Xmx` (= `JMETER_HEAP`) | 100 スレッドで 1g、300 スレッドで 2g、500 スレッドで 3〜4g | **Xms と Xmx は同じ値にする** (拡張時の停止を避ける) |
| `-XX:MaxMetaspaceSize` | 256m | 既定 |
| GC | G1 (Java 21 の既定) | 変更不要。GC ログが要るなら `-Xlog:gc*` を `JMETER_HEAP` に足す |
| Docker Desktop のメモリ割り当て | JMeter ヒープ + アプリ側コンテナ + 2GB 以上 | 不足すると JMeter か EAP が OOM Kill される |

**負荷生成側が先に詰まっている兆候**:

- `summary` の `Avg` が上がっているのに、対象側の CPU に余裕がある
- `jmeter.log` に `OutOfMemoryError` / `Connection reset` が多発
- スレッド数を増やしてもスループットが伸びない (頭打ち)

この場合はスレッド数を減らす、ThinkTime を増やす、ヒープを増やす、
もしくは負荷生成を複数コンテナへ分ける (分散実行) を検討する。

### 6.10 結果 (jtl) に保存する項目

| 項目 | 既定 | 意味 | 外すとどうなるか |
| --- | --- | --- | --- |
| `time` / `timestamp_format=ms` | true | 開始時刻 (epoch ms) | 時系列グラフが作れない |
| `label` | true | サンプル名 | ラベル別集計ができない |
| `elapsed` | (常時) | 応答時間 | 最重要指標 |
| `latency` | true | 最初の 1 バイトまで | `elapsed - latency` = 本文転送時間 |
| `connect_time` | true | TCP 接続確立まで | 増加は接続枯渇の兆候 |
| `response_code` / `response_message` | true | ステータス | エラーの切り分け |
| `successful` | true | 成功判定 (アサーション込み) | エラー率が出ない |
| `thread_counts` | true | 実行中スレッド数 | 「どの負荷レベルで折れたか」が追えない |
| `bytes` / `sent_bytes` | true | 送受信量 | 帯域の頭打ち判定ができない |
| `url` | true | 実際に叩いた URL | リダイレクト追跡ができない |
| `assertion_results_failure_message` | true | 失敗理由 | 失敗の原因が分からない |
| `response_data` | **false** | 応答本文 | true にすると数十倍に肥大。デバッグ時のみ |
| `response_data.on_error` | false | 失敗時のみ本文 | 容量と原因調査の折衷案として有効 |
| `requestHeaders` / `responseHeaders` / `samplerData` | false | 要求・応答ヘッダ / 送信データ | デバッグ用 |
| `idle_time` | true | タイマーの待ち時間 | ThinkTime 込みの見かけ上の間隔を追うとき |
| `subresults` | true | サブサンプル (リダイレクト先・埋め込みリソース) | 内訳が追えない |
| `hostname` | false | 実行ホスト名 | 分散実行では true |

**容量の目安**: CSV で 1 サンプルあたり約 150〜250 バイト。
50 req/s × 1 時間 = 18 万サンプル ≒ 30〜45 MB。
XML + 応答本文ありだと同条件で数 GB になりうる。

### 6.11 HTML ダッシュボード

| プロパティ | 既定 | 意味 / 推奨 |
| --- | --- | --- |
| `jmeter.reportgenerator.apdex_satisfied_threshold` | `500` | Apdex の「満足」上限 (ms)。**画面系 500 / API 200〜300** |
| `jmeter.reportgenerator.apdex_tolerated_threshold` | `2000` | 「許容」上限 (ms)。慣例は満足の 4 倍 |
| `jmeter.reportgenerator.overall_granularity` | `5000` | 時系列グラフの粒度 (ms)。5 分試験なら 1000〜5000、1 時間超なら 15000〜60000 |
| `aggregate_rpt_pct1/2/3` | `90/95/99` | 統計表のパーセンタイル |
| `jmeter.reportgenerator.report_title` | `JMeter Load Test Report` | レポートの見出し |
| `jmeter.reportgenerator.sample_filter` | (未設定) | 集計対象を正規表現で絞る |
| `jmeter.reportgenerator.start_date` / `end_date` | (未設定) | 集計範囲 (epoch ms)。ウォームアップを外すのに使う |

Apdex は **閾値を実際の SLA に合わせない限り意味が無い**。
既定のままの 0.9 を「良好」と報告しないこと。

```
  Apdex = (満足したサンプル数 + 許容できたサンプル数 / 2) ÷ 全サンプル数
```

| Apdex | 評価 |
| --- | --- |
| 0.94 〜 1.00 | Excellent |
| 0.85 〜 0.93 | Good |
| 0.70 〜 0.84 | Fair |
| 0.50 〜 0.69 | Poor |
| 〜 0.49 | Unacceptable |

---

## 7. 結果の読み方と合否基準

### 7.1 見る順番

1. **エラー率** — まずここ。エラーが多い状態の応答時間に意味は無い
2. **スループット (req/s)** — 目標流量に届いているか。届いていないならスレッド数か ThinkTime の設計ミス
3. **95 / 99 パーセンタイル応答時間** — SLA 判定はここで行う
4. **応答時間の時系列** — 右肩上がりならリーク・蓄積、階段状ならスケール変化
5. **アクティブスレッド数との対応** — どの負荷レベルで折れたか
6. **latency と connect の内訳** — connect が伸びていれば接続枯渇、latency が伸びていればサーバ処理

### 7.2 平均を信じない

| 指標 | 何が分かるか | 落とし穴 |
| --- | --- | --- |
| 平均 (Average) | 全体の傾向 | 外れ値に引きずられ、かつ外れ値を隠す。**単独で使わない** |
| 中央値 (Median, 50%ile) | 典型的なユーザ体験 | 遅い側の実態は見えない |
| 90%ile | 「たいていの人」の上限 | — |
| **95%ile** | SLA の定義によく使う | **合否はここで判定するのが一般的** |
| 99%ile | 最悪ケースに近い | サンプル数が少ないと不安定 |
| 最大 | 外れ値 1 件 | GC やネットワークの一瞬の詰まりで簡単に跳ねる |

### 7.3 合否基準の例 (テンプレート)

| 観点 | 基準 | この構成での確認方法 |
| --- | --- | --- |
| エラー率 | 0.1% 未満 | `summary-stats.txt` / `JMETER_MAX_ERROR_RATE=0.1` で自動判定 |
| 応答時間 | 95%ile ≤ 2.0 秒 (画面) / ≤ 500 ms (API) | HTML レポートの統計表 |
| スループット | 目標 50 req/s 以上 | 同 Throughput |
| Apdex | 0.85 以上 | HTML レポートの APDEX (閾値を SLA に合わせてから) |
| 安定性 | 応答時間が試験時間を通じて右肩上がりでない | 応答時間の時系列グラフ |
| 資源 | アプリ側のヒープが回復する / 接続数が発散しない | `docker stats`、EAP のログ、`alb-healthcheck` の状態 |

---

## 8. この compose 構成に固有の注意

### 8.1 トレース (ADOT / X-Ray) が全量サンプリングになっている

compose の front/back は `OTEL_TRACES_SAMPLER=parentbased_always_on` (全量) で動く。
**性能試験ではこれが無視できないオーバーヘッドになる**(スパン生成・送信・Collector の処理)。

| 目的 | 推奨 |
| --- | --- |
| アプリ本来の性能を測る | サンプリングを下げる: `-e OTEL_TRACES_SAMPLER=parentbased_traceidratio -e OTEL_TRACES_SAMPLER_ARG=0.05` で front/back を起動し直す |
| 計装込みの実態を測る | 全量のまま (本番も全量なら、こちらが正しい) |

どちらで測ったかを `run-info.txt` と併せて必ず記録すること。

### 8.2 起動待ちとヘルスチェック

frontend / backend の `start_period` は 120 秒。**起動直後は必ず遅い**。
`docker compose ps` が healthy になってから、さらにスモークを 1 回流してから本試験へ進む。

```bash
docker compose ps                                  # healthy を確認
curl -s http://localhost:8580/targets | head -20   # ALB から見たターゲット状態
```

### 8.3 同居しているコンテナの影響

ローカルでは JMeter・EAP×2・MySQL・Valkey・ADOT・WireMock 群が **同じ CPU を分け合う**。

- 絶対値 (何 TPS 出るか) は本番の参考にならない
- **変更前後の比較** (同じ条件で測り直す) には十分に使える
- Docker Desktop の CPU/メモリ割り当ては測定条件の一部。`run-info.txt` と一緒に控える

### 8.4 MySQL / Valkey がボトルネックになりやすい

ローカルの MySQL は 1 コンテナ。Aurora Serverless v2 + RDS Proxy とは
コネクション数もスケールも別物。DB が先に詰まったときは、

```bash
docker compose exec mysql mysql -uroot -p -e "SHOW GLOBAL STATUS LIKE 'Threads_%'; SHOW PROCESSLIST;"
docker stats --no-stream
```

で、詰まりがアプリなのか DB なのかを切り分ける。

### 8.5 EFS 偽装への書き込み

front/back はログを `/mnt/logs` (named volume) へ書く。負荷試験中はログ量が増え、
`cwagent` が tail して `cloudwatch-logs-mock` へ送る。長時間試験ではボリュームの
使用量に注意する (`docker system df -v`)。

---

## 9. トラブルシューティング

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `対象へ到達できないため試験を開始しない` | 対象コンテナが未起動 / 起動途中 | `docker compose ps` で healthy を確認。省略するなら `-e JMETER_PRECHECK=false` |
| `Non HTTP response code: org.apache.http.NoHttpResponseException` | サーバ側が Keep-Alive 接続を先に閉じた | `httpclient4.idletimeout` をサーバの keepalive より短く / `validate_after_inactivity` を 1700 前後に |
| `Connection reset` / `Broken pipe` が多発 | 接続の枯渇、またはサーバ側の同時接続上限 | スレッド数を下げる、Keep-Alive を有効にする、サーバ側の上限を確認 |
| `java.net.BindException: Address already in use` | 負荷生成側のエフェメラルポート枯渇 | Keep-Alive を有効化、ThinkTime を増やす、スレッド数を下げる |
| `OutOfMemoryError: Java heap space` (JMeter 側) | ヒープ不足 / 計画内にリスナーがある | `JMETER_HEAP` を上げる、リスナーを削除、`response_data=false` を確認 |
| HTML レポートが空 / `statistics.json` が 0 件 | jtl が XML 形式 | CSV で実行し直す (`JMETER_RESULTS_FORMAT=csv`) |
| `An error occurred: Unknown arg: Files/Git/...` | **Windows の Git Bash** が `/path` を Windows パスへ変換した | `MSYS2_ARG_CONV_EXCL='*'` を付けて実行するか、PowerShell から実行する |
| GUI で jtl を開くと列がずれる | GUI 側の区切り文字設定が違う | GUI の「結果ファイル設定」で区切りをカンマに。または `jmeter.save.saveservice.default_delimiter` を合わせる |
| 進捗の `summary` 件数が極端に少ない | トランザクションコントローラが `parent=true` | `parent=false` にする (6.6 参照) |
| 結果ディレクトリが root 所有で消せない (Linux ホスト) | コンテナが root で書いた | `docker compose --profile loadtest run --rm --user "$(id -u):$(id -g)" jmeter run ...` |
| `PKIX path building failed` | 自己証明書が JMeter のトラストストアに無い | `pki-init` を起動してから実行 (`docker compose up -d pki-init`)。`doctor` で証明書の件数を確認 |
| 試験は流れるがエラー率 100% | 対象パスが存在しない | `targets.json` の `path` を確認。`doctor` の到達確認は「HTTP 応答が返ること」しか見ていない (404 でも到達扱い) |

---

## 10. CI から回す

```bash
# エラー率 0.5% を超えたら終了コード 2
docker compose --profile loadtest run --rm \
  -e JMETER_TARGET=frontend \
  -e JMETER_THREADS=50 -e JMETER_RAMPUP=50 -e JMETER_DURATION=600 \
  -e JMETER_MAX_ERROR_RATE=0.5 \
  -e JMETER_RUN_NAME="ci-${BUILD_NUMBER}" \
  jmeter run ci-scenario.jmx
```

| 終了コード | 意味 |
| --- | --- |
| 0 | 正常終了 (エラー率の上限を指定していれば、それも満たしている) |
| 1 | JMeter の実行失敗 (計画が壊れている / 到達不可 など) |
| 2 | エラー率が `JMETER_MAX_ERROR_RATE` を超えた |

応答時間でも落としたい場合は `report/statistics.json` を読む:

```bash
run=$(cat compose/jmeter/results/LATEST.txt)
jq -e '.Total.pct2ResTime < 2000' "compose/jmeter/results/$run/report/statistics.json"
```

---

## 11. 実 AWS (ECS) へ持っていくときの差分

| ローカル (この構成) | 実 AWS | 持っていくときの注意 |
| --- | --- | --- |
| `jmeter` コンテナが compose ネットワーク内から叩く | 別 VPC / 別アカウントの負荷生成環境、または Fargate タスクとして起動 | セキュリティグループで ALB への通信を許可する |
| 投げ先は `targets.json` のサービス名 | ALB の DNS 名 | `targets.json` を書き換えるだけで済むようにしてある |
| 自己証明書 (`cacert.crt`) を取り込む | ACM の証明書 (公的 CA) | トラストストアの取り込みは不要になる |
| 1 コンテナで数百スレッド | 分散実行 (コントローラ + 複数ワーカー) | 1 ノードの限界 (200〜300 スレッド) を超えるなら分散が必要 |
| 結果はホストの `results/` | S3 へアップロード | `run-info.txt` ごと保管すると再現できる |
| ADOT は全量サンプリング | 本番のサンプリング率 | 測定条件として必ず記録する |
| 負荷生成とアプリが同居 | 別ホスト | ローカルの絶対値は本番の予測に使わない |

---

## 関連ドキュメント

- [`compose/jmeter/README.md`](../compose/jmeter/README.md) — サービスの使い方 (短縮版)
- [`compose/jmeter/test-plans/README.md`](../compose/jmeter/test-plans/README.md) — .jmx の置き方と差し替え可能なプロパティ
- [`compose/jmeter/results/README.md`](../compose/jmeter/results/README.md) — 結果ファイルと GUI での開き方
- [`docs/JMETER-SETTINGS.xlsx`](JMETER-SETTINGS.xlsx) — 本書の表を Excel 14 シートにまとめたもの
- [`docs/ALB-HEALTHCHECK.md`](ALB-HEALTHCHECK.md) — 負荷中のターゲット状態の見かた
- [`docs/TLS-SELF-SIGNED-ALB.md`](TLS-SELF-SIGNED-ALB.md) — HTTPS 経路とトラストストア
