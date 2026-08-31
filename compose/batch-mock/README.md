# batch-mock — 同じ EFS をマウントするバッチサーバーの偽装

実構成では、`frontend` / `backend` と同じ EFS (アクセスポイント不使用) を
**バッチサーバー**もマウントし、バッチが置いたファイルをアプリが読む
(あるいはその逆) という使い方をする。

ここで問題になるのは、**「マウントできている」ことと「置いたものが相手から
同じように見える」ことは別物**だという点。次のような食い違いは、コンテナを
1 つ覗いただけでは分からない。

| 症状 | 原因 |
|---|---|
| バッチが書いたファイルをアプリが更新できない | `uid:gid` がずれている / 親ディレクトリに setgid (2775) が付いていない |
| バッチが作ったディレクトリの配下へアプリが書けない | 作成時の `umask` が `0022` で group の write ビットが落ちている |
| 更新が一方からしか見えない | 共有ボリュームではなくコンテナごとの複製になっている |
| シンボリックリンクが片方のコンテナでだけ壊れて見える | リンクを**絶対パス**で張っており、マウント先が異なるコンテナで解決できない |

`batch-mock` はこの確認のためだけのサービスで、**EFS へ書く側**を受け持つ。
書いたものが各コンテナからどう見えるかの突き合わせは、
`build_and_verify.sh` の `--keep-container-mode logs` にある
**「EFS マウント伝播確認 (偽装バッチサーバー経由)」**が行う。

| ファイル | 役割 |
|---|---|
| `efs-propagation.sh` | 偽装本体 兼 CLI。POSIX sh だけで動く (python 不要、alpine でそのまま動く) |

## compose での位置づけ

```yaml
batch-mock:
  image: alpine:3.21
  user: "6301:6302"          # efs-mock が chown する値と必ず合わせる
  environment:
    BATCH_MOCK_CLI: /opt/batch-mock/efs-propagation.sh
    BATCH_MOCK_EFS_DIRS: /mnt/logs /mnt/data
  volumes:
    - ./compose/batch-mock/efs-propagation.sh:/opt/batch-mock/efs-propagation.sh:ro
    - efs-logs:/mnt/logs     # front/back と同じ named volume
    - efs-data:/mnt/data
  depends_on:
    efs-mock:
      condition: service_healthy
```

`user:` を `6301:6302` にしてあるのが要点で、実環境のバッチサーバーと同じ所有者で
ファイルを作る。`efs-mock` の初期化値 (`chown 6301:6302` / `chmod 2775`) と
ずれていると、書けたつもりで他コンテナから更新できないファイルができる。

`frontend` / `backend` は `group_add: "6302"` で GID を共有しているため、
`batch-mock` が作ったファイル (mode 664 / setgid 継承のディレクトリ) を
そのまま読み書きできる。

## CLI

```
efs-propagation.sh init                 マウントポイント配下の作業領域を用意する
efs-propagation.sh ready                作業領域が使える状態かを確かめる (healthcheck 用)
efs-propagation.sh mounts               EFS として扱うマウント先を 1 行ずつ出力する
efs-propagation.sh write <印> <本文>    ファイル・ディレクトリ・シンボリックリンクを作る
efs-propagation.sh append <印> <本文>   シンボリックリンク経由で追記する
efs-propagation.sh list <印>            作ったものを一覧する
efs-propagation.sh cleanup <印>         作ったものを消す
```

終了コードは `0` 成功 / `1` 失敗 / `2` 使い方の誤り。

`write` は各マウント先 (`/mnt/logs`, `/mnt/data`) の直下の `batch-mock/` へ、
次の 4 つを作る。

| パス | 種別 |
|---|---|
| `batch-mock/<印>.d` | ディレクトリ (mode 2775) |
| `batch-mock/<印>.d/payload.txt` | ファイル (mode 664)。本文を書き込む |
| `batch-mock/<印>-file.link` | `<印>.d/payload.txt` への**相対**シンボリックリンク |
| `batch-mock/<印>-dir.link` | `<印>.d` への**相対**シンボリックリンク |

出力の `read=` 行が「他コンテナが読むべきパス」で、必ずシンボリックリンクを指す。
リンクをたどれるかどうかまで含めて確認させるため。

### シンボリックリンクを相対パスで張る理由

同じ named volume でも、マウント先はコンテナごとに違ってよい
(`frontend` は `/mnt/logs`、`efs-mock` は `/mnt/efs/logs`)。
絶対パス (`/mnt/logs/batch-mock/<印>.d/payload.txt`) で張ると、`/mnt/logs` を
持たないコンテナではリンク先を解決できず、**そのコンテナでだけ壊れて見える**。
相対パス (`<印>.d/payload.txt`) なら、どのマウント先でも同じように解決できる。

## 手で確かめる

```console
$ docker compose exec batch-mock /bin/sh /opt/batch-mock/efs-propagation.sh write demo "hello from batch"
$ docker compose exec frontend cat /mnt/logs/batch-mock/demo-file.link
hello from batch
$ docker compose exec batch-mock /bin/sh /opt/batch-mock/efs-propagation.sh append demo "updated"
$ docker compose exec backend cat /mnt/logs/batch-mock/demo-file.link
hello from batch
updated
$ docker compose exec batch-mock /bin/sh /opt/batch-mock/efs-propagation.sh cleanup demo
```

`build_and_verify.sh --keep-container-mode logs` からは、この一連 (作成 → 書き換え
→ 削除) を全コンテナに対して自動で突き合わせられる。

## alpine には bash が無い

`batch-mock` と `efs-mock` は `alpine` ベースのため `/bin/bash` を持たない。
`build_and_verify.sh` の対話接続は `/bin/bash` → `/bin/sh` の順にシェルを解決するので、
`logs` モードの `bash へ接続` からそのまま入れる (POSIX sh のセッションになる)。
