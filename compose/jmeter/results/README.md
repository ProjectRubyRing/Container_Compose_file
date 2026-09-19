# results — ★試験結果の出力先 (git 管理外)

`jmeter` コンテナは 1 回の実行につき 1 つのディレクトリを作る。

```
results/
  20260919-093932_sample-frontend_frontend/   # <日時>_<計画名>_<対象>
    result.jtl          # ★JMeter GUI のリスナーで開く結果ファイル
    report/index.html   # ★HTML ダッシュボード (ブラウザで開く)
    jmeter.log          # JMeter 自身のログ (エラーの一次調査)
    summary.log         # 実行中の標準出力 (summariser の進捗)
    summary-stats.txt   # 一次集計 (サンプル数 / エラー率 / 平均・パーセンタイル / スループット)
    run-info.txt        # 実行条件 (対象・負荷条件・JMeter/Java のバージョン)
    plan.jmx            # 実行したテスト計画のコピー
  LATEST.txt            # 最後に実行した結果のディレクトリ名
  latest -> ...         # 同じものへのシンボリックリンク (作れる環境のみ)
```

## JMeter GUI で結果を開く

1. JMeter GUI を起動し、テスト計画へリスナーを追加する
   (例: 「結果をツリーで表示」「統計レポート」「集計レポート」「応答時間の推移」)
2. リスナーの **「結果のファイル名」** 欄に `result.jtl` を指定して「参照」から開く
3. 読み込むと、そのリスナーの形式で集計・表示される

CSV 形式 (既定) はどのリスナーでも開けるが、**応答本文は保存していない**ため
「結果をツリーで表示」で中身までは見られない。中身が要るときは XML 形式で実行する:

```bash
docker compose --profile loadtest run --rm \
  -e JMETER_RESULTS_FORMAT=xml -e JMETER_SAVE_RESPONSE_DATA=true \
  jmeter run my-plan.jmx
```

XML 形式ではファイルが大きくなり、HTML ダッシュボードは生成できない
(ダッシュボードの入力は CSV のみ)。原因調査の再実行に限って使うこと。

## 片付け

```bash
docker compose --profile loadtest run --rm jmeter clean            # 7 日より古い結果を削除
docker compose --profile loadtest run --rm jmeter clean --days 30  # 30 日より古い結果
docker compose --profile loadtest run --rm jmeter clean --all      # 全部消す
```

このディレクトリの中身は `.gitignore` でコミット対象から外してある
(README.md と .gitkeep だけを管理対象にする)。
