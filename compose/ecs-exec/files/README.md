# ecs-exec のファイル受け渡し場所 (`/work`)

このディレクトリは `ecs-exec` コンテナの `/work` にマウントされる。
ホストと「ECS タスクの中」との受け渡しはここを経由する。

```bash
# ホストで置いたファイルを frontend (app-front) へ送り込む
cp ./myapp.war compose/ecs-exec/files/
docker compose exec ecs-exec \
  ecs-exec put /work/myapp.war app-front:/opt/server/standalone/deployments/myapp.war

# backend (app-back) の中のファイルをここへ取り出す
docker compose exec ecs-exec \
  ecs-exec get app-back:/mnt/logs/app-back.log /work/app-back.log
```

`ecs-exec put` の第 1 引数は絶対パスでなくてもよく、その場合は `/work`
(環境変数 `ECS_EXEC_FILES_DIR`) の下を探す。`ecs-exec get` の書き出し先も
相対パスなら `/work` の下になる。

中身は git 管理外 (`.gitignore`)。この README と `.gitkeep` だけを管理する。

送り込みは実 ECS Exec と同じ「base64 にしてコマンド行へ載せる」方式で、
docker cp は使っていない。仕組みは [docs/ECS-EXEC.md](../../../docs/ECS-EXEC.md) を参照。
