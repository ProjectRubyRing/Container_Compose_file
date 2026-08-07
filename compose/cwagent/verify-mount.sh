#!/bin/sh
# =============================================================================
# cwagent マウント/権限/設定パス 自己診断ラッパー (ローカル compose 専用)
# =============================================================================
# 目的:
#   CloudWatch Agent のイメージは診断向けのツールが乏しく、
#   `docker compose exec cwagent bash` での目視確認が現実的でない。
#   そこで「エージェント本体を起動する直前に、同じコンテナ・同じマウント名前空間で」
#   検証を実行し、結果を **stdout (= docker compose logs / ビルドログ)** へ出力する。
#
#   ここで検証するのは以下の 3 点:
#     (1) compose の volumes 指定が実際にマウントとして成立しているか
#         (/proc/self/mountinfo に mount point として現れるか)
#     (2) 偽装 EFS の POSIX 権限 (UID 6301 / GID 6302, mode 2775) に対して
#         cwagent プロセスの実効 uid/gid/補助グループで読めるのか
#     (3) cwagent 設定 (logs_collected.files.collect_list[].file_path) の
#         ディレクトリ構造が実在し、glob に一致するファイルを open(2) できるか
#
#   最後に必ずエージェント本体を exec する。検証は診断であって門番ではないため、
#   ここでの FAIL は起動を止めない (ログと healthcheck に出るだけ)。
#
# 実 ECS との差異:
#   ECS taskdef ではこのラッパーを挟まず、イメージ既定のコマンドで起動する。
#   ラッパーはローカル compose の entrypoint 上書きでのみ有効。
#
# 出力の読み方:
#   [cwagent-verify][boot]      ... 起動直後の 1 回目の評価
#   [cwagent-verify][recheck N] ... アプリがログを書き始めた後の再評価
#   [cwagent-log]               ... エージェント自身のログファイルの中継 (存在する場合)
#   各行の PASS / FAIL / WARN / INFO と、末尾の RESULT 行で総合判定する。
#
#   確認コマンド:
#     docker compose logs cwagent | grep cwagent-verify
# -----------------------------------------------------------------------------
# 環境変数 (compose.yaml で調整可能):
#   CWA_VERIFY_MOUNTS            検証対象マウントポイント (空白区切り)   既定: /mnt/logs
#   CWA_VERIFY_CONFIG_DIR        設定ファイル配置ディレクトリ            既定: /etc/cwagentconfig
#   CWA_VERIFY_CONFIG_FILE       主設定ファイル (存在形態を個別に判定)
#                                                既定: <CONFIG_DIR>/cwagent-config.json
#   CWA_VERIFY_EXPECT_OWNER      期待する所有者 uid:gid                  既定: 6301:6302
#   CWA_VERIFY_EXPECT_MODE       期待するモード (下位 3 桁で比較)        既定: 775
#   CWA_VERIFY_RECHECK_COUNT     起動後の再評価回数                      既定: 5
#   CWA_VERIFY_RECHECK_INTERVAL  再評価の間隔 (秒)                       既定: 20
#   CWA_VERIFY_RELAY_AGENT_LOG   エージェントログファイルを中継 (1/0)    既定: 1
#   CWA_START_CMD                エージェント本体のパス (引数省略時)
# =============================================================================

CWA_VERIFY_MOUNTS="${CWA_VERIFY_MOUNTS:-/mnt/logs}"
CWA_VERIFY_CONFIG_DIR="${CWA_VERIFY_CONFIG_DIR:-/etc/cwagentconfig}"
CWA_VERIFY_CONFIG_FILE="${CWA_VERIFY_CONFIG_FILE:-${CWA_VERIFY_CONFIG_DIR}/cwagent-config.json}"
CWA_VERIFY_EXPECT_OWNER="${CWA_VERIFY_EXPECT_OWNER:-6301:6302}"
CWA_VERIFY_EXPECT_MODE="${CWA_VERIFY_EXPECT_MODE:-775}"
CWA_VERIFY_RECHECK_COUNT="${CWA_VERIFY_RECHECK_COUNT:-5}"
CWA_VERIFY_RECHECK_INTERVAL="${CWA_VERIFY_RECHECK_INTERVAL:-20}"
CWA_VERIFY_RELAY_AGENT_LOG="${CWA_VERIFY_RELAY_AGENT_LOG:-1}"
CWA_START_CMD="${CWA_START_CMD:-/opt/aws/amazon-cloudwatch-agent/bin/start-amazon-cloudwatch-agent}"

AGENT_HOME=/opt/aws/amazon-cloudwatch-agent
AGENT_STATE_DIR="${AGENT_HOME}/logs/state"
AGENT_LOG_FILE="${AGENT_HOME}/logs/amazon-cloudwatch-agent.log"
AGENT_TRANSLATED_JSON="${AGENT_HOME}/etc/amazon-cloudwatch-agent.json"

# healthcheck / verify-local.sh から参照する結果ファイル
RESULT_BOOT=/tmp/cwagent-verify.boot.result     # 起動時評価 (healthcheck が参照)
RESULT_LATEST=/tmp/cwagent-verify.latest.result # 最新評価 (再評価のたび上書き)

# --- 出力ヘルパ --------------------------------------------------------------
TAG="[boot]"
N_PASS=0
N_FAIL=0
N_WARN=0
VERDICT=UNKNOWN

say()  { printf '[cwagent-verify]%s %s\n' "$TAG" "$*"; }
info() { say "INFO  $*"; }
pass() { N_PASS=$((N_PASS + 1)); say "PASS  $*"; }
warn() { N_WARN=$((N_WARN + 1)); say "WARN  $*"; }
fail() { N_FAIL=$((N_FAIL + 1)); say "FAIL  $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- 権限ビット判定 (mode の 1 桁を受け取る) ---------------------------------
has_r() { case "$1" in 4 | 5 | 6 | 7) return 0 ;; esac; return 1; }
has_x() { case "$1" in 1 | 3 | 5 | 7) return 0 ;; esac; return 1; }

# mode 文字列を下位 3 桁へ正規化する (2775 -> 775, 44 -> 044)
mode_low3() {
  _m="$1"
  while [ "${#_m}" -gt 3 ]; do _m="${_m#?}"; done
  while [ "${#_m}" -lt 3 ]; do _m="0${_m}"; done
  printf '%s' "$_m"
}

# other 桁 (下位 3 桁の 3 文字目) を取り出す
mode_other_digit() {
  _l3="$(mode_low3 "$1")"
  _r="${_l3#?}"
  printf '%s' "${_r#?}"
}

# stat(1) の単項目取得 (無ければ空文字)
stat_one() {
  have stat || return 0
  stat -c "$1" "$2" 2>/dev/null
}

# =============================================================================
# 検証本体
#   引数: $1 = タグ文字列, $2 = strict (1 ならログファイル 0 件を FAIL 扱い)
#   結果はグローバル VERDICT に格納する (say() の出力を握り潰さないため、
#   コマンド置換ではなくグローバル変数で返す)
#   関数内で set -- を使うが、関数のローカルな位置パラメータなので
#   呼び出し元 (エージェント起動用の "$@") には影響しない
# =============================================================================
report_once() {
  TAG="$1"
  STRICT="$2"
  N_PASS=0
  N_FAIL=0
  N_WARN=0

  say "=============== cwagent mount/permission diagnostics ==============="

  # ---------------------------------------------------------------------------
  # 1. cwagent プロセスの実効 ID
  #    「6301:6302 を考慮しなくてよいのか」を判断するための一次情報。
  # ---------------------------------------------------------------------------
  P_UID=""
  P_GID=""
  P_GROUPS=""
  if have id; then
    P_UID="$(id -u 2>/dev/null)"
    P_GID="$(id -g 2>/dev/null)"
    P_GROUPS="$(id -G 2>/dev/null)"
  fi
  if [ -z "$P_UID" ] && [ -r /proc/self/status ]; then
    # id(1) が無くても Linux なら /proc から取得できる
    while IFS= read -r _line; do
      case "$_line" in
        Uid:*) set -- $_line; P_UID="$2" ;;
        Gid:*) set -- $_line; P_GID="$2" ;;
        Groups:*) P_GROUPS="${_line#Groups:}" ;;
      esac
    done < /proc/self/status
  fi
  info "agent identity: uid=${P_UID:-?} gid=${P_GID:-?} groups=[${P_GROUPS:-?}]"

  EXPECT_GID="${CWA_VERIFY_EXPECT_OWNER#*:}"
  HAS_EFS_GID=0
  for _g in $P_GROUPS $P_GID; do
    [ "$_g" = "$EXPECT_GID" ] && HAS_EFS_GID=1
  done
  IS_ROOT=0
  [ "$P_UID" = "0" ] && IS_ROOT=1

  if [ "$IS_ROOT" = "1" ]; then
    info "uid=0 のため DAC (owner/group/other の権限ビット) はバイパスされる"
    info "  => 6301:6302 を満たさなくても読めるが、それは root 実行に依存した結果"
  fi
  if [ "$HAS_EFS_GID" = "1" ]; then
    pass "GID ${EXPECT_GID} を保持している (compose の group_add が効いている)"
  else
    warn "GID ${EXPECT_GID} を保持していない。非 root 化すると /mnt/logs 配下の"
    warn "  group 限定ファイル (mode 0640 等) を読めなくなる。group_add 指定を確認すること"
  fi

  # ---------------------------------------------------------------------------
  # 2. volumes 指定が実際にマウントとして成立しているか
  #    /proc/self/mountinfo に mount point として現れるかで判定する。
  #    現れない場合は compose の volumes が効かず、イメージ内の空ディレクトリを見ている。
  # ---------------------------------------------------------------------------
  for MP in $CWA_VERIFY_MOUNTS; do
    say "---- mount point: ${MP} ----"

    M_FOUND=0
    M_DEV=""
    M_ROOT=""
    M_OPTS=""
    M_FSTYPE=""
    M_SRC=""
    if [ -r /proc/self/mountinfo ]; then
      while IFS= read -r _line; do
        # mountinfo: [1]id [2]parent [3]major:minor [4]root [5]mountpoint [6]opts ... - [n]fstype [n+1]source
        set -- $_line
        if [ "$5" = "$MP" ]; then
          M_FOUND=1
          M_DEV="$3"
          M_ROOT="$4"
          M_OPTS="$6"
          M_FSTYPE=""
          M_SRC=""
          _sep=0
          for _f in "$@"; do
            case "$_sep" in
              1) M_FSTYPE="$_f"; _sep=2 ;;
              2) M_SRC="$_f"; _sep=3; break ;;
              *) [ "$_f" = "-" ] && _sep=1 ;;
            esac
          done
        fi
      done < /proc/self/mountinfo
    else
      warn "/proc/self/mountinfo を読めないためマウント判定をスキップ"
    fi

    if [ "$M_FOUND" = "1" ]; then
      pass "マウント成立: ${MP}"
      info "  dev=${M_DEV} fstype=${M_FSTYPE:-?} source=${M_SRC:-?} subtree=${M_ROOT} opts=${M_OPTS}"
      case ",${M_OPTS}," in
        *,ro,*) info "  read-only マウント。cwagent は tail のみなので :ro で要件を満たす" ;;
        *)      info "  read-write マウント。tail のみなら :ro でも動作する" ;;
      esac
    else
      fail "${MP} はマウントポイントではない = compose の volumes 指定が効いていない"
      fail "  compose.yaml の cwagent.volumes に 'efs-logs:${MP}:ro' があるか確認すること"
    fi

    # ---------------------------------------------------------------------------
    # 3. マウントポイントの所有者 / モード (偽装 EFS の 6301:6302 / 2775)
    # ---------------------------------------------------------------------------
    if [ ! -d "$MP" ]; then
      fail "${MP} がディレクトリとして存在しない"
      continue
    fi

    D_UID="$(stat_one '%u' "$MP")"
    D_GID="$(stat_one '%g' "$MP")"
    D_MODE="$(stat_one '%a' "$MP")"
    if [ -n "$D_MODE" ]; then
      info "${MP} owner=${D_UID}:${D_GID} mode=${D_MODE}"

      if [ "${D_UID}:${D_GID}" = "$CWA_VERIFY_EXPECT_OWNER" ]; then
        pass "所有者が期待どおり (${CWA_VERIFY_EXPECT_OWNER}) = efs-mock の初期化が反映されている"
      else
        warn "所有者が ${D_UID}:${D_GID} で期待値 ${CWA_VERIFY_EXPECT_OWNER} と異なる"
        warn "  efs-mock の初期化前にマウントされたか、別ボリュームを見ている可能性がある"
      fi
      if [ "$(mode_low3 "$D_MODE")" = "$(mode_low3 "$CWA_VERIFY_EXPECT_MODE")" ]; then
        pass "モードが期待どおり (下位3桁=$(mode_low3 "$D_MODE"))"
      else
        warn "モードが ${D_MODE} で期待値 ${CWA_VERIFY_EXPECT_MODE} と異なる"
      fi

      # other ビットでのアクセス可否 = 「6301:6302 を考慮せずに読めるか」の根拠
      D_OTH="$(mode_other_digit "$D_MODE")"
      if has_r "$D_OTH" && has_x "$D_OTH"; then
        info "other に r-x があるため、GID ${EXPECT_GID} を持たなくても一覧/走査は可能"
      elif [ "$IS_ROOT" = "1" ]; then
        warn "other に r-x が無い。今は uid=0 で読めているだけで、非 root 化すると走査不可"
      else
        fail "other に r-x が無く GID ${EXPECT_GID} も無いため ${MP} を走査できない"
      fi
    else
      warn "stat(1) が無いため ${MP} の所有者/モードを取得できない"
    fi

    # 権限ビットの解釈ではなく、実際に opendir できるかを実測する
    if ! have ls; then
      warn "ls(1) が無いため ${MP} の opendir 実測をスキップ"
    elif ls "$MP" >/dev/null 2>&1; then
      pass "${MP} のディレクトリ一覧取得に成功 (実測)"
    else
      fail "${MP} のディレクトリ一覧を取得できない (opendir 失敗)"
    fi
  done

  # ---------------------------------------------------------------------------
  # 4. 設定ファイルの探索と file_path (glob) の実アクセス検証
  # ---------------------------------------------------------------------------
  say "---- cwagent config: ${CWA_VERIFY_CONFIG_DIR} ----"

  # このイメージには ls(1) / cat(1) が入っていないため、ホストから
  #   docker compose exec cwagent ls /etc/cwagentconfig
  # を実行すると "exec ls: executable file not found in $PATH" になる。
  # これは「設定ファイルが無い」ではなく「ls が無い」だけなので、判定材料にしてはいけない。
  # ここではシェル組み込み (glob と test) だけで存在形態を確定させ、ログに残す。
  if [ ! -e "$CWA_VERIFY_CONFIG_DIR" ]; then
    fail "${CWA_VERIFY_CONFIG_DIR} が存在しない = volumes 指定が効いていない"
  elif [ ! -d "$CWA_VERIFY_CONFIG_DIR" ]; then
    fail "${CWA_VERIFY_CONFIG_DIR} がディレクトリではない"
  fi

  # 主設定ファイルの存在形態。ディレクトリになっている場合は、ホスト側のパスを
  # 解決できなかった Docker が空ディレクトリを作った状態 (典型的なマウント失敗)。
  if [ -d "$CWA_VERIFY_CONFIG_FILE" ]; then
    fail "${CWA_VERIFY_CONFIG_FILE} がディレクトリになっている"
    fail "  = ホスト側の ./compose/cwagent/cwagent-config.json を解決できず Docker が空ディレクトリを作った"
    fail "  compose を実行したディレクトリと、ファイルの共有設定 (Docker Desktop の File Sharing) を確認すること"
  elif [ -f "$CWA_VERIFY_CONFIG_FILE" ]; then
    pass "主設定ファイルが存在する: ${CWA_VERIFY_CONFIG_FILE} (size=$(stat_one '%s' "$CWA_VERIFY_CONFIG_FILE"))"
  else
    info "${CWA_VERIFY_CONFIG_FILE} は無い (別名で配置 / CW_CONFIG_CONTENT 経路なら想定内)"
  fi

  # ls(1) の代わりに glob でディレクトリの中身を列挙する
  # (「/etc/cwagentconfig の内容」をホストからの exec 無しで確認できるようにする)
  _n=0
  set -- "$CWA_VERIFY_CONFIG_DIR"/*
  if [ -e "$1" ]; then
    for _e in "$@"; do
      _t=other
      [ -f "$_e" ] && _t=file
      [ -d "$_e" ] && _t=dir
      info "  entry: ${_e} (${_t} mode=$(stat_one '%a' "$_e") size=$(stat_one '%s' "$_e"))"
      _n=$((_n + 1))
    done
  fi
  [ "$_n" = "0" ] && info "  ${CWA_VERIFY_CONFIG_DIR} は空 (エントリ 0 件)"

  # translator が生成する実効設定。これが出来ていれば「設定を読み込めた」証跡になる。
  # 逆に、設定ファイルは置かれているのにこれが出来ない場合は translator 側で失敗しており、
  # 収集対象がゼロのまま起動している (= ログストリームが作られず送信も発生しない)。
  if [ -f "$AGENT_TRANSLATED_JSON" ]; then
    pass "翻訳済み設定あり: ${AGENT_TRANSLATED_JSON} = 設定を読み込めている"
  elif [ "$STRICT" = "1" ]; then
    fail "翻訳済み設定が無い: ${AGENT_TRANSLATED_JSON}"
    fail "  = 設定を読み込めていない。収集対象ゼロで起動しているため送信は一切発生しない"
    fail "  docker compose logs cwagent の 'Under path :' / 'E!' 行で translator のエラーを確認すること"
  else
    info "翻訳済み設定はまだ無い: ${AGENT_TRANSLATED_JSON} (起動直後なら想定内)"
  fi

  CFG_FILES=""
  if [ -d "$CWA_VERIFY_CONFIG_DIR" ]; then
    set -- "$CWA_VERIFY_CONFIG_DIR"/*
    if [ -e "$1" ]; then
      for _f in "$@"; do
        [ -f "$_f" ] && CFG_FILES="${CFG_FILES} ${_f}"
      done
    fi
  fi
  # 起動後は translator が生成した設定も検証対象に含める
  [ -f "$AGENT_TRANSLATED_JSON" ] && CFG_FILES="${CFG_FILES} ${AGENT_TRANSLATED_JSON}"

  if [ -z "$CFG_FILES" ]; then
    if [ -n "${CW_CONFIG_CONTENT:-}" ]; then
      info "${CWA_VERIFY_CONFIG_DIR} は空だが CW_CONFIG_CONTENT が設定済み (ECS と同じ SSM 注入経路)"
    else
      fail "設定ファイルが見つからない (${CWA_VERIFY_CONFIG_DIR} が空 / マウントされていない)"
    fi
  fi

  PATTERNS=""
  ENDPOINT=""
  for CFG in $CFG_FILES; do
    if : < "$CFG" 2>/dev/null; then
      pass "設定ファイル読み取り可: ${CFG}"
    else
      fail "設定ファイルを open できない: ${CFG}"
      continue
    fi
    if have grep && have sed; then
      _p="$(grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' "$CFG" 2>/dev/null |
        sed 's/.*:[[:space:]]*"//; s/"$//')"
      PATTERNS="${PATTERNS} ${_p}"
      if [ -z "$ENDPOINT" ]; then
        ENDPOINT="$(grep -o '"endpoint_override"[[:space:]]*:[[:space:]]*"[^"]*"' "$CFG" 2>/dev/null |
          sed -n '1s/.*:[[:space:]]*"//;1s/"$//;1p')"
      fi
    fi
  done

  if [ -z "$PATTERNS" ] && [ -n "$CFG_FILES" ]; then
    warn "設定から file_path を抽出できなかった (grep/sed 不在、または collect_list 未定義)"
  fi

  # 同一パターンの重複を除去しつつ 1 件ずつ検証する。
  # file_path は glob パターン (例: /mnt/logs/app-front*.log) なので、
  # ループ変数への展開時にシェルがパス名展開してしまわないよう noglob (set -f) にする。
  # 意図的に展開したい箇所だけ set +f で一時的に戻す。
  SEEN=""
  TOTAL_MATCHED=0
  set -f
  for PAT in $PATTERNS; do
    case " $SEEN " in *" $PAT "*) continue ;; esac
    SEEN="${SEEN} ${PAT}"

    say "---- collect_list file_path: ${PAT} ----"

    # 4-1. 設定が前提としているディレクトリ構造が実在し、走査できるか
    PDIR="${PAT%/*}"
    [ "$PDIR" = "$PAT" ] && PDIR="."
    if [ -d "$PDIR" ]; then
      pass "設定パスの親ディレクトリが存在: ${PDIR} (owner=$(stat_one '%u' "$PDIR"):$(stat_one '%g' "$PDIR") mode=$(stat_one '%a' "$PDIR"))"
      if ! have ls; then
        warn "ls(1) が無いため ${PDIR} の readdir 実測をスキップ"
      elif ls "$PDIR" >/dev/null 2>&1; then
        pass "${PDIR} を走査できる (readdir 成功)"
      else
        fail "${PDIR} を走査できない = glob 展開が常に 0 件になる"
      fi
    else
      fail "設定パスの親ディレクトリが存在しない: ${PDIR}"
      fail "  設定の file_path とマウント先のディレクトリ構造が食い違っている"
      continue
    fi

    # 4-2. glob 展開して実ファイルを open(2) できるか実測する
    #      ([ -r ] は uid=0 だと常に真になるため、必ず実際に open して確かめる)
    set +f
    set -- $PAT
    set -f
    if [ ! -e "$1" ]; then
      if [ "$STRICT" = "1" ]; then
        fail "glob に一致するファイルが 0 件: ${PAT}"
        fail "  アプリが ${PDIR} へ書いていないか、ファイル名が設定と一致していない"
      else
        info "glob に一致するファイルは現時点で 0 件 (アプリ起動直後なら想定内)"
      fi
      # 実際に何が置かれているのかを併記して、設定との食い違いを目視できるようにする
      _shown=0
      set +f
      for _e in "$PDIR"/* "$PDIR"/.??*; do
        [ -e "$_e" ] || continue
        [ "$_shown" -ge 20 ] && break
        info "  現在の ${PDIR} の内容: ${_e} (mode=$(stat_one '%a' "$_e") owner=$(stat_one '%u' "$_e"):$(stat_one '%g' "$_e"))"
        _shown=$((_shown + 1))
      done
      set -f
      [ "$_shown" = "0" ] && info "  ${PDIR} は空"
      continue
    fi

    _matched=0
    _ok=0
    for F in "$@"; do
      [ -f "$F" ] || continue
      _matched=$((_matched + 1))
      TOTAL_MATCHED=$((TOTAL_MATCHED + 1))
      _fuid="$(stat_one '%u' "$F")"
      _fgid="$(stat_one '%g' "$F")"
      _fmode="$(stat_one '%a' "$F")"
      _fsize="$(stat_one '%s' "$F")"
      if : < "$F" 2>/dev/null; then
        _ok=$((_ok + 1))
        pass "読み取り成功: ${F} (owner=${_fuid:-?}:${_fgid:-?} mode=${_fmode:-?} size=${_fsize:-?})"
        # other 読み取り不可なら、読めているのは root 権限のおかげだと明示する
        if [ -n "$_fmode" ] && ! has_r "$(mode_other_digit "$_fmode")"; then
          if [ "$IS_ROOT" = "1" ] && [ "$HAS_EFS_GID" != "1" ]; then
            warn "  ${F} は other 読み取り不可。uid=0 だから読めているだけで、"
            warn "  非 root 化する場合は GID ${_fgid:-$EXPECT_GID} が必須"
          fi
        fi
      else
        fail "読み取り不可 (open 失敗): ${F} (owner=${_fuid:-?}:${_fgid:-?} mode=${_fmode:-?})"
      fi
    done
    info "glob 一致 ${_matched} 件 / 読み取り成功 ${_ok} 件: ${PAT}"
  done
  set +f   # 以降 (state ファイル列挙など) はパス名展開を使うので必ず戻す

  # ---------------------------------------------------------------------------
  # 5. 送信側の前提条件 (エンドポイント名前解決 / 認証情報 / リージョン)
  #    「マウントは正しいのに送信されない」場合の切り分け材料。
  # ---------------------------------------------------------------------------
  say "---- delivery prerequisites ----"

  if [ -n "$ENDPOINT" ]; then
    info "logs.endpoint_override = ${ENDPOINT}"
    _hostport="${ENDPOINT#*://}"
    _hostport="${_hostport%%/*}"
    _host="${_hostport%%:*}"
    _port="${_hostport#*:}"
    [ "$_port" = "$_hostport" ] && _port=80

    if have getent; then
      if getent hosts "$_host" >/dev/null 2>&1; then
        pass "送信先の名前解決に成功: ${_host}"
      else
        fail "送信先の名前解決に失敗: ${_host} (compose ネットワーク / サービス名を確認)"
      fi
    fi
    # bash 系シェルなら /dev/tcp で TCP 接続まで確認できる (curl 不在でも可)
    if [ -n "${BASH_VERSION:-}" ]; then
      if (exec 3<>"/dev/tcp/${_host}/${_port}") 2>/dev/null; then
        pass "送信先へ TCP 接続できる: ${_host}:${_port}"
      else
        warn "送信先へ TCP 接続できない: ${_host}:${_port} (起動順序 / listen 状態を確認)"
      fi
    fi
  else
    info "endpoint_override は未設定 (実 CloudWatch Logs へ送信する構成)"
  fi

  CRED="${AWS_SHARED_CREDENTIALS_FILE:-/root/.aws/credentials}"
  if [ -f "$CRED" ]; then
    if : < "$CRED" 2>/dev/null; then
      pass "認証情報ファイルを読める: ${CRED}"
    else
      fail "認証情報ファイルを open できない: ${CRED}"
    fi
  else
    warn "認証情報ファイルが無い: ${CRED} (SigV4 署名に失敗して送信されない可能性)"
  fi
  info "AWS_REGION=${AWS_REGION:-<unset>}"

  # ---------------------------------------------------------------------------
  # 6. エージェントが実際にファイルを掴んだか (tail オフセットの state ファイル)
  #    state が出来ていれば「検知して open するところまでは到達した」証跡になる。
  #    マウント OK + state 無し = 設定 (file_path) 側の問題、と切り分けられる。
  # ---------------------------------------------------------------------------
  if [ -d "$AGENT_STATE_DIR" ]; then
    set -- "$AGENT_STATE_DIR"/*
    if [ -e "$1" ]; then
      pass "tail 状態ファイルあり = エージェントが対象ファイルを検知して読み出している"
      for S in "$@"; do
        [ -f "$S" ] || continue
        _off=""
        IFS= read -r _off < "$S" 2>/dev/null
        info "  state: ${S##*/} offset=${_off:-?}"
      done
    elif [ "$STRICT" = "1" ]; then
      fail "tail 状態ファイルが 0 件 = 対象ファイルをまだ検知していない (${AGENT_STATE_DIR})"
    else
      info "tail 状態ファイルはまだ無い (${AGENT_STATE_DIR})"
    fi
  else
    info "状態ディレクトリ未作成: ${AGENT_STATE_DIR} (エージェント初期化前なら想定内)"
  fi

  # ---------------------------------------------------------------------------
  # 総合判定
  # ---------------------------------------------------------------------------
  if [ "$N_FAIL" -gt 0 ]; then
    VERDICT=FAIL
  elif [ "$N_WARN" -gt 0 ]; then
    VERDICT=WARN
  else
    VERDICT=PASS
  fi
  say "RESULT: ${VERDICT} (pass=${N_PASS} warn=${N_WARN} fail=${N_FAIL} matched_files=${TOTAL_MATCHED})"
  say "==================================================================="

  printf '%s\n' "$VERDICT" > "$RESULT_LATEST" 2>/dev/null
}

# =============================================================================
# 起動時評価 → バックグラウンド再評価 / ログ中継 → エージェント本体を exec
# =============================================================================

# 1 回目 (起動直後)。この時点ではアプリがまだログを書いていないことがあるため
# 「glob 0 件」は FAIL にしない (STRICT=0)。healthcheck はこの結果を参照する。
report_once '[boot]' 0
printf '%s\n' "$VERDICT" > "$RESULT_BOOT" 2>/dev/null

# 2 回目以降 (バックグラウンド)。アプリが /mnt/logs へ書き始めた後の状態を評価する。
# 1 回目の再評価までは猶予を与え、2 回目以降は「0 件 = 異常」として FAIL にする。
if [ "$CWA_VERIFY_RECHECK_COUNT" -gt 0 ] 2>/dev/null; then
  (
    _i=1
    while [ "$_i" -le "$CWA_VERIFY_RECHECK_COUNT" ]; do
      sleep "$CWA_VERIFY_RECHECK_INTERVAL"
      _strict=1
      [ "$_i" -le 1 ] && _strict=0
      report_once "[recheck ${_i}/${CWA_VERIFY_RECHECK_COUNT}]" "$_strict"
      _i=$((_i + 1))
    done
  ) &
fi

# エージェント自身がログファイルへ書く構成の場合に stdout へ中継する。
# (コンテナ実行時は既定で stdout へ出るため、通常この中継は空振りする)
if [ "$CWA_VERIFY_RELAY_AGENT_LOG" = "1" ] && have tail; then
  (
    _w=0
    while [ "$_w" -lt 30 ]; do
      [ -f "$AGENT_LOG_FILE" ] && break
      sleep 2
      _w=$((_w + 1))
    done
    [ -f "$AGENT_LOG_FILE" ] || exit 0
    tail -n +1 -f "$AGENT_LOG_FILE" 2>/dev/null | while IFS= read -r _l; do
      printf '[cwagent-log] %s\n' "$_l"
    done
  ) &
fi

# --- エージェント本体へ引き渡す ----------------------------------------------
# compose で entrypoint を上書きするとイメージの CMD は消えるため、
# compose 側の command に本体パスを指定する。未指定時は既定パスへフォールバックする。
if [ "$#" -gt 0 ]; then
  say "starting agent: $*"
  exec "$@"
fi

if [ ! -x "$CWA_START_CMD" ]; then
  say "FAIL  エージェント本体が見つからない: ${CWA_START_CMD}"
  say "      compose の command / CWA_START_CMD を確認すること"
fi
say "starting agent: ${CWA_START_CMD}"
exec "$CWA_START_CMD"
