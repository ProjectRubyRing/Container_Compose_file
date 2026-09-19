# lib-ext — 追加プラグイン jar の置き場 (任意、git 管理外)

JMeter のプラグイン (jar) をここへ置くと、`jmeter` コンテナが
`-Jsearch_paths` / `-Juser.classpath` で読み込む。イメージの再ビルドは要らない。

```bash
cp jmeter-plugins-manager-1.10.jar compose/jmeter/lib-ext/
docker compose --profile loadtest run --rm jmeter doctor   # 認識件数を確認
```

## よく使うもの

| プラグイン | 用途 | 入手先 |
| --- | --- | --- |
| JMeter Plugins Manager | 他プラグインの導入管理 | https://jmeter-plugins.org/ |
| Custom Thread Groups | Stepping / Ultimate Thread Group (段階的な負荷の増減) | 同上 |
| 3 Basic Graphs | 応答時間・スループット・アクティブスレッドの時系列グラフ | 同上 |
| PerfMon (ServerAgent) | 対象サーバの CPU / メモリ / I/O をグラフに重ねる | 同上 |

## 注意

- **jar を足すと、その計画は「プラグインが入った JMeter でしか開けない」計画になる。**
  GUI 側にも同じプラグインを入れておくこと (入っていないと開いたときに要素が消える)。
- 標準要素だけで足りるなら足さないほうがよい。段階的な負荷の増減は、
  スレッドグループを複数置いて `startup.delay` をずらす形でも組める。
- 追加した jar はこのリポジトリではコミットしない (`.gitignore` 済み)。
  再現性が要るなら、バージョンを docs/JMETER-LOADTEST.md か試験仕様書に控えておくこと。
