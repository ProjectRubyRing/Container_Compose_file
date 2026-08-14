# ecs-exec のセッションログ出力先

実 ECS Exec は、クラスターの `executeCommandConfiguration.logConfiguration` を
設定すると、セッションの内容を CloudWatch Logs / S3 へ
`<task-id>/<container-name>/<session-id>` というログストリーム名で保管できる
(「誰がいつ何をしたか」の監査に使う)。

`ecs-exec` サービスはその代わりに、このディレクトリ (コンテナ内 `/var/log/ecs-exec`)
へ同じ階層でファイルを書く。

```
<task-id>/<container-name>/ecs-execute-command-<session-id>.log
```

各ファイルの先頭に、セッション ID / クラスター / タスク ARN / コンテナ /
実行したコマンド / 終了コード / 所要時間が入り、その後ろに出力が続く
(端末を張った対話セッションでは本文は記録しない)。

```bash
docker compose exec ecs-exec ecs-exec sessions              # 新しい順に一覧
docker compose exec ecs-exec ecs-exec sessions show         # 直近 1 件の中身
docker compose exec ecs-exec ecs-exec sessions show <ID の一部>
```

中身は git 管理外 (`.gitignore`)。この README と `.gitkeep` だけを管理する。
