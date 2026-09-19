# test-plans — ★GUI で作ったテスト計画 (.jmx) の置き場

手元の JMeter GUI で作った `.jmx` をこのディレクトリへ置くと、
`jmeter` コンテナがそれを非 GUI モードで実行する。

```bash
cp ~/work/my-plan.jmx compose/jmeter/test-plans/
docker compose --profile loadtest run --rm jmeter run my-plan.jmx
```

コンテナへは **読み取り専用** (`/test-plans`) でマウントされる。
実行した計画は結果ディレクトリへ `plan.jmx` としてコピーされるので、
「この結果はどの計画で出たのか」は後から必ず追える。

## 同梱サンプル

| ファイル | 内容 |
| --- | --- |
| `sample-frontend.jmx` | GET 中心の基本形。HTTP リクエスト初期値 / ヘッダ・クッキー・キャッシュマネージャ / トランザクションコントローラ / 応答アサーション / ThinkTime タイマー |
| `sample-async-post.jmx` | POST + 外部データ。CSV データセット設定で 1 リクエストごとに別データを送り、JSON ボディを Raw で投げる |
| `data/orders.csv` | 上記サンプルが読むデータ (`orderId,amount,itemCount`) |

どちらも各要素の **「コメント」欄 (GUI の Comments)** に、その設定の意味と
推奨値を書いてある。GUI で開けばそのまま読める。

## 自分の .jmx を「外から差し替えられる」ようにするコツ

サンプルと同じく、投げ先と負荷条件を `${__P(プロパティ名, 既定値)}` で書いておくと、
`.jmx` を編集せずに対象や負荷を変えられる (GUI で開いたときは既定値が使われる)。

| プロパティ | 渡ってくる値 | 対応する環境変数 |
| --- | --- | --- |
| `target.protocol` / `target.host` / `target.port` / `target.path` | `targets.json` の該当エントリ | `JMETER_TARGET` |
| `threads` | スレッド数 (同時実行ユーザ数) | `JMETER_THREADS` |
| `rampup` | 全スレッドが起動しきるまでの秒数 | `JMETER_RAMPUP` |
| `duration` | 試験時間 (秒) | `JMETER_DURATION` |
| `loops` | ループ回数 (-1 = 時間で終わるまで) | `JMETER_LOOPS` |
| `startup.delay` | 開始遅延 (秒) | `JMETER_STARTUP_DELAY` |
| `think.time.base` / `think.time.range` | 操作間の待ち時間 (ms) | `JMETER_THINK_TIME_BASE` / `_RANGE` |
| `connect.timeout` / `response.timeout` | タイムアウト (ms) | `JMETER_CONNECT_TIMEOUT` / `JMETER_RESPONSE_TIMEOUT` |

GUI で設定するときは、例えばスレッド数の欄に
`${__P(threads,10)}` と書くだけでよい (10 は GUI で開いたときの既定値)。

## 置くときの注意

- **リスナー (結果をツリーで表示 / 集計レポート 等) は入れない。**
  非 GUI 実行では結果は `-l` で指定した jtl に出る。計画側にリスナーがあると
  メモリと CPU を消費し、測定値そのものが歪む。GUI で作った計画を持ち込むときは
  リスナーを削除するか無効化しておくこと (残っていても動くが、負荷が上がる)。
- **絶対パスを書かない。** CSV データセット設定などでファイルを参照する場合は、
  コンテナ内のパス (`/test-plans/data/xxx.csv`) を使う。
  `${__P(csv.file,/test-plans/data/orders.csv)}` のように書いておくと差し替えやすい。
- **文字コードは UTF-8。** 日本語を含むデータを送る場合、CSV データセット設定の
  `fileEncoding` を UTF-8 にし、HTTP リクエスト初期値の `contentEncoding` も UTF-8 にする。
- **改行コードは LF。** `.gitattributes` で `*.jmx` は LF 固定にしてある
  (CRLF のままだとコンテナ内で読ませたときに値の末尾に CR が残ることがある)。
