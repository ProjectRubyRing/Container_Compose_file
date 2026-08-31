#!/bin/sh
# =============================================================================
# 偽装バッチサーバーの EFS 伝播確認 CLI
#
# 実環境では、frontend / backend と同じ EFS をバッチサーバーもマウントし、
# バッチが置いたファイルをアプリが読む (あるいはその逆) という使い方をする。
# ところが「マウントできている」ことと「置いたものが相手から同じように見える」
# ことは別物で、次のような食い違いが起こる。
#
#   - uid/gid と mode がずれていて、書けるが相手からは更新できない
#   - 親ディレクトリに setgid (2775) が付いておらず、配下に作ったファイルの
#     GID が引き継がれず、GID を共有する別コンテナから書けない
#   - :ro でマウントしたコンテナだけ更新が見えていない (と誤解する)
#   - シンボリックリンクを絶対パスで張っており、マウント先が異なるコンテナでは
#     リンク先を解決できない
#
# この CLI は、そうした食い違いを機械的に確かめられるようにするためのもので、
# 「偽装バッチサーバーが EFS へ書く」側だけを受け持つ。書いたものが各コンテナから
# どう見えるかの突き合わせは build_and_verify.sh の
# 「EFS マウント伝播確認 (偽装バッチサーバー経由)」が行う。
#
# 使い方:
#   efs-propagation.sh init                 マウントポイント配下の作業領域を用意する
#   efs-propagation.sh ready                作業領域が使える状態かを確かめる (healthcheck 用)
#   efs-propagation.sh mounts               EFS として扱うマウント先を 1 行ずつ出力する
#   efs-propagation.sh write <印> <本文>    ファイル・ディレクトリ・シンボリックリンクを作る
#   efs-propagation.sh append <印> <本文>   シンボリックリンク経由で追記する
#   efs-propagation.sh list <印>            作ったものを一覧する
#   efs-propagation.sh cleanup <印>         作ったものを消す
#
# 終了コード: 0 成功 / 1 失敗 / 2 使い方の誤り
#
# 依存はコンテナ内の POSIX sh と coreutils 相当のみ (python は不要)。
# alpine のような軽量イメージでそのまま動かせるようにしてある。
# =============================================================================
set -u

# EFS として扱うマウント先。compose の environment で上書きできる。
BATCH_MOCK_EFS_DIRS="${BATCH_MOCK_EFS_DIRS:-/mnt/logs /mnt/data}"
# 各マウント先の直下に作る作業ディレクトリ名。
BATCH_MOCK_WORK_SUBDIR="${BATCH_MOCK_WORK_SUBDIR:-batch-mock}"

# 作ったディレクトリ/ファイルを group-writable にする (GID を共有する
# frontend / backend から書き換えられるようにするため)。
# 既定の umask 0022 のままだと group の write ビットが落ちる。
umask 0002

err() { printf '%s\n' "$*" >&2; }

usage() {
  err "使い方: $0 {init|ready|mounts|write|append|list|cleanup} [引数...]"
}

# マウント先ごとの作業ディレクトリ。
work_dir() {
  printf '%s/%s' "${1%/}" "$BATCH_MOCK_WORK_SUBDIR"
}

# 所有者を "uid:gid" で返す (stat が無ければ空)。
owner_of() {
  if command -v stat >/dev/null 2>&1; then
    stat -c '%u:%g' "$1" 2>/dev/null && return 0
  fi
  printf '\n'
}

# mode を 8 進数で返す (stat が無ければ空)。
mode_of() {
  if command -v stat >/dev/null 2>&1; then
    stat -c '%a' "$1" 2>/dev/null && return 0
  fi
  printf '\n'
}

# setgid 付き (2775) でディレクトリを冪等に作る。
# mode の強制は所有者しかできないため、別ユーザ所有なら既存権限を尊重する。
ensure_dir() {
  mkdir -p "$1" 2>/dev/null || return 1
  chmod 2775 "$1" 2>/dev/null || :
  return 0
}

cmd_init() {
  status=0
  for root in $BATCH_MOCK_EFS_DIRS; do
    if [ ! -d "$root" ]; then
      err "[batch-mock] マウントされていません: $root"
      status=1
      continue
    fi
    if ! ensure_dir "$(work_dir "$root")"; then
      err "[batch-mock] 作業ディレクトリを作成できません: $(work_dir "$root") (uid=$(id -u) gid=$(id -g))"
      status=1
      continue
    fi
    printf '[batch-mock] ready: %s (owner=%s mode=%s)\n' \
      "$(work_dir "$root")" "$(owner_of "$(work_dir "$root")")" "$(mode_of "$(work_dir "$root")")"
  done
  return "$status"
}

cmd_ready() {
  for root in $BATCH_MOCK_EFS_DIRS; do
    work="$(work_dir "$root")"
    [ -d "$work" ] || return 1
    [ -w "$work" ] || return 1
  done
  return 0
}

cmd_mounts() {
  for root in $BATCH_MOCK_EFS_DIRS; do
    printf '%s\n' "${root%/}"
  done
}

# ファイル・ディレクトリ・シンボリックリンクを作る。
# シンボリックリンクは必ず「相対パス」で張る。絶対パスで張ると、同じボリュームを
# 別のパスへマウントしているコンテナ (例: efs-mock の /mnt/efs/logs) から
# リンク先を解決できなくなるため。
cmd_write() {
  token="$1"
  marker="$2"
  status=0
  for root in $BATCH_MOCK_EFS_DIRS; do
    work="$(work_dir "$root")"
    if ! ensure_dir "$work"; then
      err "[batch-mock] 作業ディレクトリを作成できません: $work (uid=$(id -u) gid=$(id -g))"
      status=1
      continue
    fi
    data_dir="${work}/${token}.d"
    payload="${data_dir}/payload.txt"
    file_link="${work}/${token}-file.link"
    dir_link="${work}/${token}-dir.link"
    if ! ensure_dir "$data_dir"; then
      err "[batch-mock] ディレクトリを作成できません: $data_dir"
      status=1
      continue
    fi
    if ! printf '%s\n' "$marker" > "$payload" 2>/dev/null; then
      err "[batch-mock] ファイルを作成できません: $payload"
      status=1
      continue
    fi
    chmod 664 "$payload" 2>/dev/null || :
    rm -f "$file_link" "$dir_link" 2>/dev/null || :
    ln -s "${token}.d/payload.txt" "$file_link" 2>/dev/null \
      || { err "[batch-mock] シンボリックリンクを作成できません: $file_link"; status=1; continue; }
    ln -s "${token}.d" "$dir_link" 2>/dev/null \
      || { err "[batch-mock] シンボリックリンクを作成できません: $dir_link"; status=1; continue; }

    printf 'path=%s kind=dir owner=%s mode=%s\n' "$data_dir" "$(owner_of "$data_dir")" "$(mode_of "$data_dir")"
    printf 'path=%s kind=file owner=%s mode=%s\n' "$payload" "$(owner_of "$payload")" "$(mode_of "$payload")"
    printf 'path=%s kind=symlink target=%s\n' "$file_link" "${token}.d/payload.txt"
    printf 'path=%s kind=symlink target=%s\n' "$dir_link" "${token}.d"
    # 他コンテナが読むべきパス。シンボリックリンク経由で読ませることで、
    # 「リンクをたどれるか」まで含めて確かめられるようにする。
    printf 'read=%s\n' "$file_link"
  done
  return "$status"
}

# シンボリックリンク経由で追記する (リンクをたどった先の実体が書き換わる)。
cmd_append() {
  token="$1"
  marker="$2"
  status=0
  for root in $BATCH_MOCK_EFS_DIRS; do
    file_link="$(work_dir "$root")/${token}-file.link"
    if [ ! -e "$file_link" ]; then
      err "[batch-mock] 見つかりません: $file_link"
      status=1
      continue
    fi
    if printf '%s\n' "$marker" >> "$file_link" 2>/dev/null; then
      printf 'appended=%s\n' "$file_link"
    else
      err "[batch-mock] 追記できません: $file_link"
      status=1
    fi
  done
  return "$status"
}

cmd_list() {
  token="$1"
  for root in $BATCH_MOCK_EFS_DIRS; do
    work="$(work_dir "$root")"
    for path in "${work}/${token}.d" "${work}/${token}-file.link" "${work}/${token}-dir.link"; do
      if [ -L "$path" ]; then
        printf 'path=%s kind=symlink target=%s\n' "$path" "$(readlink -- "$path" 2>/dev/null)"
      elif [ -d "$path" ]; then
        printf 'path=%s kind=dir owner=%s mode=%s\n' "$path" "$(owner_of "$path")" "$(mode_of "$path")"
      elif [ -e "$path" ]; then
        printf 'path=%s kind=file owner=%s mode=%s\n' "$path" "$(owner_of "$path")" "$(mode_of "$path")"
      else
        printf 'path=%s kind=missing\n' "$path"
      fi
    done
  done
}

cmd_cleanup() {
  token="$1"
  status=0
  for root in $BATCH_MOCK_EFS_DIRS; do
    work="$(work_dir "$root")"
    rm -f "${work}/${token}-file.link" "${work}/${token}-dir.link" 2>/dev/null || status=1
    rm -rf "${work}/${token}.d" 2>/dev/null || status=1
  done
  return "$status"
}

# 印 (token) はファイル名の一部になるため、パス区切りなどを含ませない。
validate_token() {
  case "$1" in
    ''|*/*|*..*)
      err "[batch-mock] 印には / と .. を含めない 1 語を指定してください: $1"
      return 2
      ;;
  esac
  return 0
}

subcommand="${1:-}"
[ $# -gt 0 ] && shift

case "$subcommand" in
  init)    cmd_init ;;
  ready)   cmd_ready ;;
  mounts)  cmd_mounts ;;
  write)
    [ $# -ge 2 ] || { usage; exit 2; }
    validate_token "$1" || exit 2
    cmd_write "$1" "$2"
    ;;
  append)
    [ $# -ge 2 ] || { usage; exit 2; }
    validate_token "$1" || exit 2
    cmd_append "$1" "$2"
    ;;
  list)
    [ $# -ge 1 ] || { usage; exit 2; }
    validate_token "$1" || exit 2
    cmd_list "$1"
    ;;
  cleanup)
    [ $# -ge 1 ] || { usage; exit 2; }
    validate_token "$1" || exit 2
    cmd_cleanup "$1"
    ;;
  *)
    usage
    exit 2
    ;;
esac
