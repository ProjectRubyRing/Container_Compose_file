# ECS Exec をローカルで再現する (ecs-exec)

実 AWS では、動いている ECS タスクの中へ手元から入れる。踏み台も SSH 鍵も要らず、
経路は AWS CLI と SSM だけで完結する。

```bash
aws ecs execute-command \
  --cluster myapp-local-cluster \
  --task 158d1c8083dd49d6b527399fd6414f5c \
  --container app-front \
  --interactive \
  --command "/bin/bash"
```

この仕組みには **ファイル転送の口が無い** (SCP に相当するものが無い) ため、
実運用では「中身を base64 にしてコマンド行へ載せ、コンテナ側でデコードする」という
やり方が定石になる。設定ファイルの差し替え、WAR の入れ替え、取得したログの持ち出しは、
どれもこの一手で行うことになる。

`ecs-exec` サービスは、この**コマンド体系と失敗の出方**をローカル compose へ持ち込む。
チャネルの実体は SSM ではなく `docker exec` (`/var/run/docker.sock`) だが、
利用者から見える入口・引数・出力・エラーは実物にそろえてある。

- 偽装の実装: [`compose/ecs-exec/ecs-exec.py`](../compose/ecs-exec/ecs-exec.py)
- 接続先の定義 (★差し替え可能★): [`compose/ecs-exec/tasks.json`](../compose/ecs-exec/tasks.json)
- ファイルの受け渡し場所: [`compose/ecs-exec/files/`](../compose/ecs-exec/files/README.md)
- セッションログ: [`compose/ecs-exec/sessions/`](../compose/ecs-exec/sessions/README.md)
- 検証スクリプト: [`verify-ecs-exec.sh`](../verify-ecs-exec.sh)

## 実 AWS 構成との対応

```
[実 AWS]
  手元の端末
    aws ecs execute-command --cluster ... --container app-front --interactive
      │
      ├─ ECS API (ExecuteCommand)  … enableExecuteCommand / IAM を検査し、
      │                              セッションの接続情報を返す
      └─ session-manager-plugin
           └─ SSM の制御/データチャネル (ssmmessages:*)
                └─ タスク内の ExecuteCommandAgent (SSM Agent)
                     └─ app-front コンテナの中でコマンドを pty で実行

[ローカル compose]
  ecs-exec コンテナ
    aws ecs execute-command --cluster ... --container app-front --interactive
      │                                   ↑ 引数は実物と同じ
      ├─ 偽装 ECS API   … tasks.json と docker の実状態から同じ検査をする
      └─ docker exec (/var/run/docker.sock)
           └─ frontend コンテナの中でコマンドを実行
```

| 実 AWS | ローカル | 等価性の担保 |
|---|---|---|
| `aws ecs execute-command` の引数 | 同じ (`--cluster` / `--task` / `--container` / `--interactive` / `--command`) | 省略・誤りのときの挙動も同じ (`--interactive` 必須、`--container` はタスクに複数コンテナがあるとき必須) |
| クラスター / タスク / コンテナ | `tasks.json` の階層 | クラスター名・タスク ID・コンテナ名・`runtimeId` は `ecs-metadata-mock` のタスクメタデータと同一の値 |
| コンテナ名 | `app-front` / `app-back` (+ `adot-collector` / `cwagent`) | `ecs/taskdef.json` の `containerDefinitions[].name` と一致 |
| `enableExecuteCommand` | `tasks.json` の `enable_execute_command` / `aws ecs update-service` で切り替え | false のときは実物と同じ `InvalidParameterException` |
| `ExecuteCommandAgent` の状態 | 対象コンテナが docker で動いているかから導出 | `describe-tasks` の `managedAgents[].lastStatus` に `RUNNING` / `PENDING` / `STOPPED` で出る |
| セッション ID | `ecs-execute-command-<17 桁>` | 出力の体裁 (`Starting session with SessionId: ...`) も同じ |
| セッションログ (CloudWatch Logs / S3) | `compose/ecs-exec/sessions/<task-id>/<container>/<session-id>.log` | 実物のログストリーム名と同じ階層 |
| コマンドの起動方法 | シェルを介さず argv として起動 | パイプやリダイレクトには実物と同じく `sh -c "..."` が要る |
| ファイル転送の口 | 無い (base64 をコマンド行へ載せる) | `ecs-exec put` / `get` が同じ方式を自動化する (`docker cp` は使わない) |
| SSM チャネル | `docker exec` | ここだけが構造的な差。IAM・SSM の到達性は検査しない |

## 使い方

```bash
docker compose up -d --build          # ecs-exec も一緒に起動する

# 1) 接続先とコマンド例を出す (ECS のコンテナ名 ⇄ compose サービスの対応が分かる)
docker compose exec ecs-exec ecs-exec tasks

# 2) 前提の点検 (docker ソケット / 定義 / 各コンテナの ExecuteCommandAgent)
docker compose exec ecs-exec ecs-exec doctor
```

`ecs-exec tasks` の出力例:

```
CONTAINER       COMPOSE         DOCKER              STATE       EXEC AGENT
----------------------------------------------------------------------------
app-front       frontend        frontend            running     RUNNING
app-back        backend         backend             running     RUNNING
adot-collector  adot-collector  adot-collector      running     RUNNING
cwagent         cwagent         cwagent             running     RUNNING

cluster : myapp-local-cluster
task    : 158d1c8083dd49d6b527399fd6414f5c
exec    : enableExecuteCommand=True
```

### frontend / backend の中へ入る (実物と同じコマンド)

```bash
# ★実 AWS とまったく同じ書き方。docker compose exec は既定で端末を割り当てるので
# そのまま対話シェルになる (スクリプトから呼ぶときは -T を付けて端末を切る)
docker compose exec ecs-exec \
  aws ecs execute-command \
    --cluster myapp-local-cluster \
    --task 158d1c8083dd49d6b527399fd6414f5c \
    --container app-front \
    --interactive \
    --command "/bin/bash"

# backend (app-back) はコンテナ名を変えるだけ
docker compose exec ecs-exec \
  aws ecs execute-command --cluster myapp-local-cluster \
    --task 158d1c8083dd49d6b527399fd6414f5c \
    --container app-back --interactive --command "/bin/bash"
```

タスク ID を毎回書くのが面倒なときは、実物と同じ手順で引ける:

```bash
docker compose exec ecs-exec sh -lc '
  TASK=$(aws ecs list-tasks --cluster myapp-local-cluster \
           --query "taskArns[0]" --output text | cut -d/ -f3)
  aws ecs execute-command --cluster myapp-local-cluster --task "$TASK" \
    --container app-front --interactive --command "sh -c \"id; ls -l /mnt/logs\""
'
```

補助コマンド (中では上と同じ `execute-command` を通る。実行前に等価なコマンドを表示する):

```bash
docker compose exec ecs-exec ecs-exec shell app-front          # 対話シェル
docker compose exec ecs-exec ecs-exec run app-back -- ls -l /mnt/logs
docker compose exec ecs-exec ecs-exec run app-front -- sh -c 'env | grep OTEL_'
```

### コマンドはシェルを介さない (実物と同じ制約)

`--command` はシェルに渡されず、そのまま argv として起動される。
パイプ・リダイレクト・変数展開を使うときは `sh -c` で包む必要がある。

```bash
--command "ls -l /mnt/logs"                    # OK (引数の分割だけ行われる)
--command "cat /proc/1/status | head -5"       # NG (| はファイル名として渡る)
--command "sh -c 'cat /proc/1/status | head -5'"   # OK
```

### ファイルを送り込む / 取り出す

```bash
# ホスト → コンテナ (compose/ecs-exec/files/ が ecs-exec の /work)
cp ./myapp.war compose/ecs-exec/files/
docker compose exec ecs-exec \
  ecs-exec put /work/myapp.war app-front:/opt/server/standalone/deployments/myapp.war

# 親ディレクトリの作成とパーミッション指定
docker compose exec ecs-exec \
  ecs-exec put /work/app.properties app-back:/mnt/data/conf/app.properties -p --mode 0644

# コンテナ → ホスト
docker compose exec ecs-exec \
  ecs-exec get app-back:/mnt/logs/app-back.log /work/app-back.log
```

出力例 (1 チャンクごとに 1 セッション。最後に sha256 を突き合わせる):

```
[ecs-exec] /work/myapp.war (10240 B, sha256=e96760a87768717b…) → app-front:/tmp/myapp.war
[ecs-exec] base64 13656 文字を 1 セッションに分けて送る (1 セッション 16384 文字まで)
[ecs-exec]   chunk 1/1 (13656 文字) session=ecs-execute-command-907e4aa571229819d
[ecs-exec] OK: sha256 一致 (e96760a87768717bcebcfd25ddc7d46b4dbc95a4b0014def080c08539f7d90d0)
```

#### なぜ base64 をコマンド行に載せるのか

ECS Exec には転送用の API が無く、使えるのは「コマンドを 1 本実行する」ことだけ。
しかも実物のセッションは **pty** なので、バイナリを標準入力へ流し込むと改行や
制御文字の変換で壊れる。そのため実運用では次の形に落ち着く。

```bash
# 実 AWS でもこのまま通る形 (ecs-exec put が自動化しているのと同じこと)
aws ecs execute-command --cluster <c> --task <t> --container app-front --interactive \
  --command "sh -c 'printf %s <base64 の断片> >> /tmp/x.b64'"     # 断片の数だけ繰り返す
aws ecs execute-command --cluster <c> --task <t> --container app-front --interactive \
  --command "sh -c 'base64 -d /tmp/x.b64 > /opt/app.war && rm -f /tmp/x.b64'"
```

base64 の文字種 (`A-Z a-z 0-9 + / =`) はシェルの特殊文字を含まないため、
そのままコマンド行へ載せられる。1 回のコマンド長には限りがあるので分割し
(`ECS_EXEC_PUT_CHUNK_CHARS`、既定 16384 文字)、最後に `sha256sum` で
送信元と突き合わせて壊れていないことを確認する — `ecs-exec put` はこれを行う。
取り出し (`get`) は逆に、コンテナ側で `base64` にした出力を受け取って復号する。

### セッションログ

実 ECS Exec は、クラスターの `executeCommandConfiguration.logConfiguration` を
設定するとセッションの内容を CloudWatch Logs / S3 へ
`<task-id>/<container-name>/<session-id>` で保管できる。偽装側も同じ階層で
`compose/ecs-exec/sessions/` へ書く。

```bash
docker compose exec ecs-exec ecs-exec sessions            # 新しい順に一覧
docker compose exec ecs-exec ecs-exec sessions show       # 直近 1 件の中身
```

```
# sessionId      : ecs-execute-command-00727ffd2be3972b4
# startedAt      : 2026-08-15T04:54:37.916Z
# cluster        : myapp-local-cluster
# taskArn        : arn:aws:ecs:ap-northeast-1:111122223333:task/myapp-local-cluster/158d1c…
# container      : app-front (compose: frontend / docker: frontend)
# command        : sh -c 'ls -l /mnt/logs'
# exitCode       : 0
# durationMillis : 55
```

## 接続先を変える (tasks.json)

[`compose/ecs-exec/tasks.json`](../compose/ecs-exec/tasks.json) が
「ECS のクラスター / タスク / コンテナ」と「compose サービス」の対応表になっている。

| キー | 意味 |
|---|---|
| `clusters[].name` | `--cluster` に渡すクラスター名 |
| `tasks[].task_id` | `--task` に渡すタスク ID (ARN でも可) |
| `containers[].name` | `--container` に渡す **ECS 側のコンテナ名** (`app-front` / `app-back`) |
| `containers[].compose_service` | 実際につなぐ compose サービス。ラベル `com.docker.compose.service` で引く |
| `containers[].docker_container` | ラベルで見つからないときのフォールバック (コンテナ名) |
| `containers[].exec_agent` | `auto` (docker の状態から導出) / `RUNNING` / `PENDING` / `STOPPED` の固定値 |
| `containers[].aliases` | 偽装独自の別名。`--container frontend` のように書ける (**実 AWS では通らない**) |
| `services[].enable_execute_command` | 初期状態の `enableExecuteCommand` |

コンテナを増やす場合は `containers[]` に 1 件足すだけでよい。
`exec_agent` を `STOPPED` に固定すれば、そのコンテナだけ
「エージェントが上がっていないタスク」として扱える。

## 失敗パターンを再現する

実運用で ECS Exec が通らないときの典型を、同じ例外名で再現できる。

| やること | 出るエラー | 実運用での意味 |
|---|---|---|
| `--cluster` を間違える / 省略する | `ClusterNotFoundException: Cluster not found.` | 省略時は `default` クラスターを見に行くため、クラスター名の指定漏れで必ず出る |
| 存在しないタスク ID | `InvalidParameterException: The referenced task was not found.` | タスクが置き換わって ID が変わっている |
| タスクに無いコンテナ名 | `InvalidParameterException: The container does not exist in the task.` | compose のサービス名とタスク定義のコンテナ名の取り違え |
| `--container` を省略する | `InvalidParameterException: Container name must be provided...` | 1 タスクに複数コンテナがある構成では必須 |
| `aws ecs update-service --no-enable-execute-command` のあとに実行 | `InvalidParameterException: The execute command failed because execute command was not enabled...` | **最頻出**。サービスを `--enable-execute-command` で更新しても、`--force-new-deployment` でタスクを置き換えるまで既存タスクには効かない |
| 対象コンテナを止める (`docker compose stop frontend`) | `TargetNotConnectedException: ...` | エージェントが起動途中 / タスクが停止中 |
| `--non-interactive` を付ける | `InvalidParameterException: Interactive is the only mode supported currently.` | 非対話モードは提供されていない |
| `ECS_EXEC_SIMULATE_PLUGIN_MISSING=1` | `SessionManagerPlugin is not found. ...` | 手元に session-manager-plugin を入れていない |

```bash
# 例: 「execute command が有効化されていない」状態を作って戻す
docker compose exec ecs-exec aws ecs update-service --cluster myapp-local-cluster \
  --service myapp-local-service --no-enable-execute-command
docker compose exec ecs-exec aws ecs execute-command --cluster myapp-local-cluster \
  --task 158d1c8083dd49d6b527399fd6414f5c --container app-front \
  --interactive --command "/bin/sh"          # ← InvalidParameterException
docker compose exec ecs-exec aws ecs update-service --cluster myapp-local-cluster \
  --service myapp-local-service --enable-execute-command
```

> エラー文言は実物に寄せてあるが、AWS CLI / API のバージョンによって細部の
> 言い回しが変わることがある。**例外名 (`ClusterNotFoundException` など) と
> 発生条件**が一致していることを再現の要点としている。

## 実 AWS で同じことをするための前提

この偽装は認証・IAM・SSM の到達性を検査しない。実 AWS では次の 3 つが要る。

1. **タスクロールの権限** — `ssmmessages:CreateControlChannel` /
   `CreateDataChannel` / `OpenControlChannel` / `OpenDataChannel`。
   本リポジトリでは [`ecs/iam/task-role-policy.json`](../ecs/iam/task-role-policy.json)
   の `ECSExecSSMMessages` に入れてある (ECS Exec を使わないなら削ってよい)
2. **`enableExecuteCommand` が true** — サービス / タスク側の設定。
   タスク定義ではなく **サービス (または `run-task`) のパラメータ**である点に注意

   ```bash
   aws ecs update-service --cluster <cluster> --service <service> \
     --enable-execute-command --force-new-deployment   # 既存タスクは置き換えが要る
   aws ecs describe-tasks --cluster <cluster> --tasks <task-id> \
     --query 'tasks[0].enableExecuteCommand'
   ```
3. **手元の AWS CLI に session-manager-plugin** — 未導入だと
   `SessionManagerPlugin is not found.` で止まる

補足: 実環境の切り分けには AWS が公開している
[`amazon-ecs-exec-checker`](https://github.com/aws-containers/amazon-ecs-exec-checker)
(`check-ecs-exec.sh`) が使える。`ecs-exec doctor` はその役割をローカルで担う。
タスク定義側では `linuxParameters.initProcessEnabled: true` を入れておくと、
セッションを繰り返してもゾンビプロセスが溜まらない (任意)。

## 実物との違い (意図的なもの)

| 項目 | 実 ECS Exec | この偽装 |
|---|---|---|
| チャネル | SSM (ssmmessages) | `docker exec` (`/var/run/docker.sock`) |
| 認証・認可 | IAM (呼び出し側 + タスクロール) | 検査しない |
| pty | 常に張る | 呼び出し側に端末があるときだけ張る (パイプでも中身が壊れないようにするため) |
| リモートの終了コード | CLI は返さない (常に 0) | 既定で返す。`ECS_EXEC_PROPAGATE_EXIT_CODE=0` で実物と同じ挙動になる |
| 対応する API | ECS の全 API | `list-clusters` / `list-tasks` / `describe-tasks` / `execute-command` / `update-service` のみ |
| `--query` | JMESPath 全体 | `name` / `a.b` / `list[0]` / `list[*].name` のみ (解釈できない式はエラーにする) |
| `describe-tasks` の応答 | AWS の全フィールド | 主要フィールド + 偽装側の補足キー (`x-localComposeService` / `x-localDockerContainer` / `x-localDockerState`) |
| コンテナ名 | タスク定義の名前のみ | `aliases` (`frontend` / `backend`) も受け付ける |
| `update-service` | サービス設定全般 | `--enable-execute-command` / `--no-enable-execute-command` のみ |

## 検証

```bash
./verify-ecs-exec.sh
```

正常系 (接続・コマンド実行・ファイル往復) と失敗系 (クラスター名誤り・
コンテナ名誤り・exec 無効化・エージェント停止) を機械的に確認する。
所要 1 分程度で、`frontend` / `backend` が起動していれば実行できる。

## よくある食い違い

- **`docker compose exec ecs-exec ...` と `docker compose exec frontend ...` は別物**。
  後者は compose の機能で直接コンテナに入るもので、実 AWS には対応物が無い。
  ECS Exec の手順を確認したいときは前者を使う
- **`--container` に compose のサービス名を書いてしまう**。
  実 AWS で通るのはタスク定義のコンテナ名 (`app-front` / `app-back`)。
  偽装は `aliases` のおかげで `frontend` でも通ってしまうので、
  実環境向けの手順書には ECS 側の名前を書くこと
- **`enableExecuteCommand` を有効にしただけで既存タスクに入れると思っている**。
  実 AWS では設定変更後にタスクの置き換え (`--force-new-deployment`) が必要
- **`ecs-exec put` の投入先がコンテナの書き込み権限を持たない**。
  `frontend` / `backend` は jboss (UID 185) で動くため、`/opt/server/...` や
  `/mnt/logs` (GID 6302) 以外は書けないことがある。実 AWS のセッションも
  タスク定義の `user` で動くので事情は同じ。テスト目的で回避するなら
  `--user root` を付ける (**偽装限定の逃げ道**であり、実 ECS Exec には無い)
