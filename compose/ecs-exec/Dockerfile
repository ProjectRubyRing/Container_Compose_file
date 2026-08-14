# =============================================================================
# ecs-exec — ECS Exec (aws ecs execute-command) のローカル代替
# ---------------------------------------------------------------------------
# 実 AWS の ECS Exec は「AWS CLI + session-manager-plugin」→ SSM の制御/データ
# チャネル → コンテナ内の ExecuteCommandAgent という経路でつながる。
# ローカルにはその経路が無いため、チャネルの実体だけを docker CLI
# (/var/run/docker.sock 経由の docker exec) に置き換える。
#
# したがってこのイメージに必要なのは docker CLI と python3 だけ:
#   docker-cli … SSM チャネルの代役 (frontend / backend の中でコマンドを実行する)
#   python3    … 偽装本体 (ecs-exec.py)。標準ライブラリしか使わない
#
# 入口は 2 つ。どちらも ecs-exec.py を呼ぶ薄いラッパー:
#   aws       … 実 AWS CLI と同じ書き方をする入口 (aws ecs ... のみ)
#   ecs-exec  … 補助コマンド (tasks / doctor / shell / run / put / get / sessions)
#
# ecs-exec.py は compose.yaml から読み取り専用でマウントし直しているため、
# 直したいときはホスト側のファイルを編集してコンテナを再起動するだけでよい
# (ラッパーが python3 で実行するので、マウント側に実行権限は要らない)。
# =============================================================================
# ベースは他の補助コンテナ (tls-verifier / efs-mock) と同じ alpine にそろえる。
# docker-cli は alpine の community リポジトリに入っている (docker:cli イメージでも可)
FROM alpine:3.21

RUN apk add --no-cache docker-cli python3

COPY ecs-exec.py /opt/ecs-exec/ecs-exec.py

RUN printf '%s\n' \
      '#!/bin/sh' \
      'exec python3 /opt/ecs-exec/ecs-exec.py --entrypoint aws "$@"' \
      > /usr/local/bin/aws \
 && printf '%s\n' \
      '#!/bin/sh' \
      'exec python3 /opt/ecs-exec/ecs-exec.py --entrypoint ecs-exec "$@"' \
      > /usr/local/bin/ecs-exec \
 && chmod 0755 /usr/local/bin/aws /usr/local/bin/ecs-exec \
 && mkdir -p /var/lib/ecs-exec /var/log/ecs-exec /work

WORKDIR /work

# 常駐させて `docker compose exec ecs-exec ...` の入口にする
# (alpine の busybox sleep は "infinity" を受け付けないため efs-mock と同じ書き方)
CMD ["tail", "-f", "/dev/null"]
