# jmeter — 性能試験 (Apache JMeter) の実行コンテナ

手元の JMeter GUI で作った `.jmx` を、compose のネットワークの中から非 GUI モードで
実行し、**GUI で開ける結果ファイル (jtl)** と **HTML ダッシュボード** を出す。

設定項目の意味と推奨値は **[docs/JMETER-LOADTEST.md](../../docs/JMETER-LOADTEST.md)**、
一覧表は **[docs/JMETER-SETTINGS.xlsx](../../docs/JMETER-SETTINGS.xlsx)** にまとめてある。

## 3 ステップ

```bash
# 1) GUI で作った .jmx を置く
cp ~/work/my-plan.jmx compose/jmeter/test-plans/

# 2) 実行 (投げ先の既定は frontend)
docker compose --profile loadtest run --rm jmeter run my-plan.jmx

# 3) 結果を見る
#    compose/jmeter/results/<日時>_<計画名>_<対象>/
#      result.jtl        → JMeter GUI のリスナー (結果をツリーで表示 / 統計レポート) で開く
#      report/index.html → ブラウザで開く (HTML ダッシュボード)
```

`--profile loadtest` を付けているのは、この サービスが常駐ではなく
「実行するたびに起動して終わるジョブ」だから (通常の `docker compose up` では起動しない)。

## サブコマンド

| コマンド | 内容 |
| --- | --- |
| `run [PLAN.jmx] [--target NAME] [--name RUNID] [-- <jmeter 引数>]` | 実行。計画を省略すると `test-plans/` に 1 つだけあるものか同梱サンプル |
| `list` | 置いてあるテスト計画の一覧 |
| `targets` | 投げ先の一覧 (`targets.json`) |
| `doctor` | 自己診断 (マウント・設定・JMeter/Java) と全対象への到達確認 |
| `report <結果ディレクトリ>` | 既存の jtl から HTML ダッシュボードを作り直す |
| `clean [--days N \| --all]` | 古い結果の削除 (既定は 7 日より古いもの) |
| `version` | JMeter / Java のバージョン |
| `exec <引数...>` | 素の `jmeter` コマンドをそのまま実行 |

## 投げ先の切り替え

```bash
# backend へ
docker compose --profile loadtest run --rm -e JMETER_TARGET=backend jmeter run

# ALB 経由 (リスナールール込みの経路)
docker compose --profile loadtest run --rm -e JMETER_TARGET=alb jmeter run

# 一時的に対象だけ変える (環境変数ではなく引数で)
docker compose --profile loadtest run --rm jmeter run my-plan.jmx --target alb-https
```

対象の定義は **[targets.json](targets.json)** (★差し替え可能★)。
`jmeter-run` がここから引いた値を `-Jtarget.host` などで JMeter へ渡し、
テスト計画側は `${__P(target.host,frontend)}` で受ける。
このため **同じ .jmx が GUI でも CLI でもそのまま動く** (GUI では既定値が使われる)。

## 負荷条件の指定

```bash
docker compose --profile loadtest run --rm \
  -e JMETER_THREADS=100 \
  -e JMETER_RAMPUP=100 \
  -e JMETER_DURATION=900 \
  -e JMETER_THINK_TIME_BASE=3000 \
  -e JMETER_THINK_TIME_RANGE=2000 \
  -e JMETER_HEAP="-Xms2g -Xmx2g" \
  jmeter run my-plan.jmx
```

環境変数の一覧と推奨値は compose.yaml の `jmeter:` の `environment:` にコメントつきで、
根拠は docs/JMETER-LOADTEST.md に書いてある。

## ファイル構成

| パス | 役割 |
| --- | --- |
| `Dockerfile` | JMeter 本体 (Apache 配布の tgz を SHA-512 検証して展開) + jq/curl |
| `jmeter-run.sh` | 実行ラッパー (★差し替え可能★。ホスト側を直せば再ビルド不要) |
| `user.properties` | JMeter の実行時設定 (★差し替え可能★。保存項目・タイムアウト・レポート閾値) |
| `targets.json` | 投げ先の定義 (★差し替え可能★) |
| `test-plans/` | ★GUI で作った .jmx の置き場。`data/` に CSV データ |
| `results/` | ★結果の出力先 (git 管理外) |
| `lib-ext/` | 追加プラグイン jar の置き場 (任意、git 管理外) |

## 注意

- **GUI でそのまま負荷をかけないこと。** GUI 実行は描画とリスナー保持で CPU と
  ヒープを食い、測っているのがアプリではなく JMeter 自身になる。GUI は
  「計画を作る」「結果を見る」ためだけに使い、走らせるのはこのコンテナで行う。
- **JMeter のバージョンは GUI 側とそろえること。** `.env` の `JMETER_VERSION`
  (既定 5.6.3) がイメージのバージョン。GUI が古いと、新しい版で保存した .jmx を
  開けないことがある。
- このコンテナは `depends_on` を持たない (投げ先を選べるようにするため)。
  対象が起動していないときは、試験を始める前に到達確認で止まる。
