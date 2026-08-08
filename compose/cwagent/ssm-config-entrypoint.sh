#!/bin/sh
# =============================================================================
# CloudWatch Agent 設定を「SSM Parameter Store の SecureString (JSON 文字列)」から
# 注入する ECS の仕組みを、ローカル compose で偽装するラッパー
# (ローカル compose 専用。実 ECS ではこのファイルはコンテナに入らない)
# =============================================================================
# 実 ECS で起きていること (2 段構え):
#
#   (1) SSM → 環境変数  … タスク定義の secrets で
#         { "name": "CW_CONFIG_CONTENT",
#           "valueFrom": "arn:aws:ssm:...:parameter/<APP>/<ENV>/cwagent-config" }
#       と書くと、**ECS エージェントがタスク起動時に** Parameter Store から値を取得し
#       (SecureString なら KMS で復号し)、復号後の JSON 文字列を環境変数として
#       コンテナに与える。コンテナ側から見えるのは「復号済みの JSON 文字列が
#       入った環境変数」だけで、SSM も KMS も見えない。
#
#   (2) 環境変数 → 設定  … CloudWatch Agent はコンテナ実行時
#       (RUN_IN_CONTAINER=True)、設定ディレクトリ /etc/cwagentconfig を
#       `--input-dir` として読み、**中の JSON ファイルをすべてマージ**して起動する
#       (EKS で ConfigMap を複数マウントする運用と同じ仕組み)。
#       `CW_CONFIG_CONTENT` はこの入口へ流し込まれる「既定の設定」として扱われる。
#
# このラッパーが偽装するのは上記のうち **(1) の SSM 取得部分と、(2) への流し込み**。
# マージと設定解釈そのものは**実エージェントのバイナリにそのまま行わせる**ので、
# 「ローカルで動いた = 同じ JSON を Parameter Store に入れれば ECS でも動く」が成立する。
#
#   ローカル: ./compose/cwagent/ssm/*.json   (= Parameter Store に入れる値そのもの)
#                     │  このラッパー (SSM 取得 + KMS 復号の偽装)
#                     ▼
#             環境変数 CW_CONFIG_CONTENT / CW_CONFIG_CONTENT_MID
#                     │  このラッパー (デフォルトロードの偽装)
#                     ▼
#             /etc/cwagentconfig/00-cwagent-config.json
#             /etc/cwagentconfig/10-cwagent-config-mid.json
#                     │  ★ここから先は実エージェントの処理 (マージ / translator)
#                     ▼
#             /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
#
# -----------------------------------------------------------------------------
# なぜ「環境変数をそのまま実エージェントに渡す」だけでは不十分なのか
# -----------------------------------------------------------------------------
# 実エージェントが特別扱いする環境変数は `CW_CONFIG_CONTENT` **1 本だけ**で、
# `CW_CONFIG_CONTENT_MID` のような追加変数は素のままでは読まれない。
# 「主設定 + 追加設定」を複数のパラメータに分けたい場合 (パラメータのサイズ上限を
# 避ける / 設定の管理主体を分ける など) は、ECS 側でも **同じ materialize 処理を
# entryPoint で挟む**必要がある。ecs/taskdef.json の cwagent コンテナには、
# このスクリプトと等価なインライン sh を `entryPoint` として入れてある
# (docs/CWAGENT-SSM-CONFIG.md 参照)。
#
# また、materialize 後は環境変数を **unset してから** エージェントを起動する。
# 実エージェント側にも `CW_CONFIG_CONTENT` を読む経路があるため、残したままだと
# 同じ設定が二重に読み込まれ collect_list が重複する可能性があるため。
#
# -----------------------------------------------------------------------------
# 出力の読み方:
#   [cwagent-ssm] の各行と、末尾の RESULT 行で判定する。
#     docker compose logs cwagent-ssm | grep cwagent-ssm
#   結果は /tmp/cwagent-ssm.result にも書く (PASS / WARN / FAIL)。
# -----------------------------------------------------------------------------
# 環境変数 (compose.yaml で調整可能):
#   CWA_SSM_PARAMS        注入する「環境変数名=パラメータ名」の空白区切りリスト。
#                         **並び順がそのままマージ順**になる (先頭が既定の設定)。
#                         既定: "CW_CONFIG_CONTENT=/myapp/local/cwagent-config
#                                CW_CONFIG_CONTENT_MID=/myapp/local/cwagent-config-mid"
#   CWA_SSM_VALUE_DIR     パラメータの値 (JSON) を置いたディレクトリ。
#                         ファイル名は <パラメータ名の最後の要素>.json
#                         既定: /opt/cwagent-ssm/params
#   CWA_SSM_CONFIG_DIR    materialize 先 (= エージェントの --input-dir)
#                         既定: /etc/cwagentconfig
#   CWA_SSM_CLEAN_DIR     起動時に materialize 先の *.json を消す (1/0) 既定: 1
#   CWA_SSM_UNSET_AFTER   materialize 後に環境変数を unset する (1/0)   既定: 1
#                         0 にすると ECS と同じ「環境変数に JSON が入ったまま」で起動する
#   CWA_SSM_STRICT        FAIL があれば起動を止める (1/0)               既定: 0
# =============================================================================

CWA_SSM_PARAMS="${CWA_SSM_PARAMS:-CW_CONFIG_CONTENT=/myapp/local/cwagent-config CW_CONFIG_CONTENT_MID=/myapp/local/cwagent-config-mid}"
CWA_SSM_VALUE_DIR="${CWA_SSM_VALUE_DIR:-/opt/cwagent-ssm/params}"
CWA_SSM_CONFIG_DIR="${CWA_SSM_CONFIG_DIR:-/etc/cwagentconfig}"
CWA_SSM_CLEAN_DIR="${CWA_SSM_CLEAN_DIR:-1}"
CWA_SSM_UNSET_AFTER="${CWA_SSM_UNSET_AFTER:-1}"
CWA_SSM_STRICT="${CWA_SSM_STRICT:-0}"

RESULT_FILE=/tmp/cwagent-ssm.result

N_PASS=0
N_WARN=0
N_FAIL=0
N_MATERIALIZED=0

say()  { printf '[cwagent-ssm] %s\n' "$*"; }
info() { say "INFO  $*"; }
pass() { N_PASS=$((N_PASS + 1)); say "PASS  $*"; }
warn() { N_WARN=$((N_WARN + 1)); say "WARN  $*"; }
fail() { N_FAIL=$((N_FAIL + 1)); say "FAIL  $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# stat(1) の単項目取得 (無ければ空文字)。イメージによっては stat も無い
stat_one() {
  have stat || return 0
  stat -c "$1" "$2" 2>/dev/null
}

# --- cat(1) が無いイメージでも動くテキスト操作 (組み込みの read/printf のみ) ---
# 最終行に改行が無いファイルも取りこぼさないよう `|| [ -n "$_l" ]` を付ける。
copy_text() {
  while IFS= read -r _l || [ -n "$_l" ]; do
    printf '%s\n' "$_l"
  done < "$1" > "$2"
}

read_text() {
  _acc=""
  while IFS= read -r _l || [ -n "$_l" ]; do
    if [ -z "$_acc" ]; then
      _acc="$_l"
    else
      _acc="${_acc}
${_l}"
    fi
  done < "$1"
  printf '%s' "$_acc"
}

# 先頭の空白を読み飛ばし、最初の非空白文字が '{' なら真 (JSON らしさの簡易判定)
looks_like_json() {
  _fc=""
  IFS= read -r _fc < "$1" 2>/dev/null
  while :; do
    case "$_fc" in
      ' '*) _fc="${_fc# }" ;;
      '	'*) _fc="${_fc#	}" ;;
      *) break ;;
    esac
  done
  case "$_fc" in
    '{'*) return 0 ;;
  esac
  return 1
}

# --- 位置パラメータを使う処理は必ず関数に閉じ込める --------------------------
# このスクリプトは最後に `exec "$@"` で後段 (verify-mount.sh → エージェント本体) へ
# 引き渡すため、トップレベルで `set --` を実行すると引数が壊れる。
# glob 展開の結果を反復する処理は関数内 (= ローカルな位置パラメータ) で行う。

# materialize 先に残っている前回の結果を消す (パラメータを減らしたときの取り残し防止)
clean_config_dir() {
  have rm || { warn "rm(1) が無いため既存ファイルを削除できない (前回の設定が残る可能性)"; return 0; }
  set -- "$CWA_SSM_CONFIG_DIR"/*.json
  [ -e "$1" ] || return 0
  if rm -f "$@" 2>/dev/null; then
    info "既存の materialize 結果を削除した (冪等化)"
  else
    warn "既存の materialize 結果を削除できなかった"
  fi
}

# materialize 先の最終状態を列挙する (ls(1) 不在でも動くよう glob で列挙)
list_config_dir() {
  N_MATERIALIZED=0
  set -- "$CWA_SSM_CONFIG_DIR"/*
  [ -e "$1" ] || return 0
  for _e in "$@"; do
    [ -f "$_e" ] || continue
    info "  ${_e} ($(stat_one '%s' "$_e") bytes mode=$(stat_one '%a' "$_e"))"
    N_MATERIALIZED=$((N_MATERIALIZED + 1))
  done
}

say "=========== CW_CONFIG_CONTENT injection (SSM emulation) ==========="
info "materialize 先 (エージェントの --input-dir): ${CWA_SSM_CONFIG_DIR}"
info "パラメータ値の格納元 (Parameter Store の代替): ${CWA_SSM_VALUE_DIR}"

# -----------------------------------------------------------------------------
# 0. materialize 先の準備
#    このイメージには mkdir(1) が無い場合があるため、compose 側で tmpfs
#    (ECS では task volume) を ${CWA_SSM_CONFIG_DIR} にマウントしてディレクトリの
#    存在を保証している。mkdir があれば保険として使う。
# -----------------------------------------------------------------------------
if [ ! -d "$CWA_SSM_CONFIG_DIR" ] && have mkdir; then
  mkdir -p "$CWA_SSM_CONFIG_DIR" 2>/dev/null && info "${CWA_SSM_CONFIG_DIR} を作成した"
fi

if [ ! -d "$CWA_SSM_CONFIG_DIR" ]; then
  fail "${CWA_SSM_CONFIG_DIR} がディレクトリとして存在しない"
  fail "  compose.yaml の cwagent-ssm.tmpfs (ECS では volumes/mountPoints) を確認すること"
else
  pass "materialize 先を確認: ${CWA_SSM_CONFIG_DIR} (mode=$(stat_one '%a' "$CWA_SSM_CONFIG_DIR"))"
  [ "$CWA_SSM_CLEAN_DIR" = "1" ] && clean_config_dir
fi

# -----------------------------------------------------------------------------
# 1. パラメータの解決 (= ECS エージェントによる secrets 解決の偽装) と materialize
# -----------------------------------------------------------------------------
_idx=0
UNSET_LIST=""
MATERIALIZED=""

for _entry in $CWA_SSM_PARAMS; do
  case "$_entry" in
    *=*) ;;
    *)
      warn "CWA_SSM_PARAMS の書式が不正 (期待: 環境変数名=/パラメータ名): ${_entry}"
      continue
      ;;
  esac

  _var="${_entry%%=*}"       # 例: CW_CONFIG_CONTENT
  _param="${_entry#*=}"      # 例: /myapp/local/cwagent-config
  _base="${_param##*/}"      # 例: cwagent-config

  # 先頭 (_idx=0) が「デフォルトロードされる主設定」。以降は追加設定。
  # ファイル名の数値プレフィクスがそのままエージェントのマージ順になる。
  _prefix=$(printf '%02d' $((_idx * 10)))
  _dst="${CWA_SSM_CONFIG_DIR}/${_prefix}-${_base}.json"
  _idx=$((_idx + 1))

  if [ "$_prefix" = "00" ]; then
    _role="デフォルトロードされる主設定"
  else
    _role="追加設定 (マージ順 ${_prefix})"
  fi

  say "---- ${_var} (${_role}) ----"
  info "  SSM パラメータ名: ${_param} (type=SecureString 想定)"

  # 値の解決順:
  #   (a) 環境変数に既に入っている
  #       = compose の environment: / env_file: で注入した場合。
  #         ECS の secrets 注入と完全に同じ状態からの検証になる。
  #   (b) ${CWA_SSM_VALUE_DIR}/<base>.json
  #       = Parameter Store の値をローカルのファイルとして置いたもの (既定経路)。
  #         JSON を YAML へ直書きせずに済むのでこちらを既定にしている。
  eval "_val=\"\${${_var}:-}\""

  if [ -n "$_val" ]; then
    if printf '%s\n' "$_val" > "$_dst" 2>/dev/null; then
      pass "  環境変数から取得 (ECS の secrets 注入と同一の状態) → ${_dst}"
      info "    取得元: 環境変数 ${_var}"
    else
      fail "  ${_dst} へ書き込めない"
      continue
    fi
  else
    _srcfile="${CWA_SSM_VALUE_DIR}/${_base}.json"
    if [ ! -f "$_srcfile" ]; then
      fail "  パラメータの値が見つからない: 環境変数 ${_var} も ${_srcfile} も無い"
      fail "    compose.yaml の cwagent-ssm.volumes (${CWA_SSM_VALUE_DIR}) と"
      fail "    CWA_SSM_PARAMS のパラメータ名を確認すること"
      continue
    fi
    if copy_text "$_srcfile" "$_dst" 2>/dev/null; then
      pass "  Parameter Store から取得 (偽装: KMS 復号済みの値) → ${_dst}"
      info "    取得元: ${_srcfile}"
      # 環境変数を残す設定のときだけ、ECS と同じ
      # 「環境変数に JSON 文字列が入っている」状態も作る。
      if [ "$CWA_SSM_UNSET_AFTER" != "1" ]; then
        _content="$(read_text "$_srcfile")"
        eval "export ${_var}=\"\$_content\""
        info "    環境変数 ${_var} にも同じ JSON 文字列を設定した"
      fi
    else
      fail "  ${_srcfile} → ${_dst} のコピーに失敗"
      continue
    fi
  fi

  # --- materialize 結果の健全性チェック -------------------------------------
  _size="$(stat_one '%s' "$_dst")"
  if [ "${_size:-0}" = "0" ]; then
    fail "  materialize 結果が空: ${_dst} (パラメータの値が空文字の可能性)"
  elif ! looks_like_json "$_dst"; then
    warn "  JSON オブジェクト ('{' 始まり) になっていない: ${_dst}"
    warn "    Parameter Store の値が JSON かどうか確認すること"
  else
    pass "  JSON として materialize 済み: ${_dst} (${_size:-?} bytes)"
  fi

  MATERIALIZED="${MATERIALIZED} ${_dst}"
  UNSET_LIST="${UNSET_LIST} ${_var}"
done

# -----------------------------------------------------------------------------
# 2. 環境変数の後始末
#    実エージェント側にも CW_CONFIG_CONTENT を読む経路があるため、materialize 済みの
#    状態で残しておくと同じ設定を二重に読む可能性がある。
# -----------------------------------------------------------------------------
if [ "$CWA_SSM_UNSET_AFTER" = "1" ]; then
  for _v in $UNSET_LIST; do
    unset "$_v" 2>/dev/null || true
  done
  [ -n "$UNSET_LIST" ] && info "materialize 後に環境変数を unset した (二重ロード防止):${UNSET_LIST}"
else
  info "環境変数を残したままエージェントを起動する (CWA_SSM_UNSET_AFTER=0)"
fi

# 下流 (verify-mount.sh / 検証スクリプト) から参照できるよう結果を残す
CWA_SSM_MATERIALIZED="${MATERIALIZED# }"
export CWA_SSM_MATERIALIZED

# -----------------------------------------------------------------------------
# 3. materialize 先の最終状態
#    ここに並んだファイルが、エージェントが --input-dir で読み込みマージする対象。
# -----------------------------------------------------------------------------
say "---- ${CWA_SSM_CONFIG_DIR} の最終状態 (エージェントのマージ対象) ----"
list_config_dir
if [ "$N_MATERIALIZED" = "0" ]; then
  fail "  materialize されたファイルが 0 件 = エージェントは収集対象ゼロで起動する"
else
  pass "  materialize 済みファイル ${N_MATERIALIZED} 件 (これらがマージされて実効設定になる)"
  info "  マージ結果は /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json で確認する"
fi

# -----------------------------------------------------------------------------
# 総合判定
# -----------------------------------------------------------------------------
if [ "$N_FAIL" -gt 0 ]; then
  VERDICT=FAIL
elif [ "$N_WARN" -gt 0 ]; then
  VERDICT=WARN
else
  VERDICT=PASS
fi
say "RESULT: ${VERDICT} (pass=${N_PASS} warn=${N_WARN} fail=${N_FAIL} materialized=${N_MATERIALIZED})"
say "=================================================================="
printf '%s\n' "$VERDICT" > "$RESULT_FILE" 2>/dev/null

if [ "$VERDICT" = "FAIL" ] && [ "$CWA_SSM_STRICT" = "1" ]; then
  say "CWA_SSM_STRICT=1 のため起動を中止する"
  exit 1
fi

# -----------------------------------------------------------------------------
# 4. 後段へ引き渡す
#    compose の command には verify-mount.sh (既存の自己診断ラッパー) と
#    エージェント本体を並べてあるため、ここでの exec で
#      ssm-config-entrypoint.sh → verify-mount.sh → start-amazon-cloudwatch-agent
#    という鎖になる。
# -----------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  say "next: $*"
  exec "$@"
fi

say "next: /opt/aws/amazon-cloudwatch-agent/bin/start-amazon-cloudwatch-agent"
exec /opt/aws/amazon-cloudwatch-agent/bin/start-amazon-cloudwatch-agent
