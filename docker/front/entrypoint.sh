#!/usr/bin/env bash
# =============================================================================
# フロントコンテナ用 Entrypoint
# - ADOT Java Agent jar の存在検証
# - OTEL_* 環境変数のデフォルト設定 (タスク定義 / compose 側の値が常に優先)
# - JAVA_TOOL_OPTIONS へ -javaagent を「二重登録なし」で追加
# - exec で JBoss EAP (standalone.sh) を PID 1 として起動
# =============================================================================
set -euo pipefail

log()  { echo "[entrypoint][front] $*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

# --- 必須前提の検証 ----------------------------------------------------------
: "${JBOSS_HOME:?JBOSS_HOME must be set (e.g. /opt/server)}"
[[ -x "${JBOSS_HOME}/bin/standalone.sh" ]] || fail "standalone.sh not found under ${JBOSS_HOME}/bin"

ADOT_AGENT_JAR="${ADOT_AGENT_JAR:-/opt/adot/aws-opentelemetry-agent.jar}"
[[ -f "${ADOT_AGENT_JAR}" ]] || fail "ADOT Java Agent not found: ${ADOT_AGENT_JAR}"

# DB 接続に必要な環境変数の検証 (XA データソースが ${env.*} を参照するため必須)
for v in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD; do
  [[ -n "${!v:-}" ]] || fail "required environment variable ${v} is not set"
done

# --- OTel 設定 (未設定時のみデフォルトを補完) --------------------------------
export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-app-front}"
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}"
export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"
export OTEL_PROPAGATORS="${OTEL_PROPAGATORS:-xray,tracecontext,baggage}"
export OTEL_TRACES_SAMPLER="${OTEL_TRACES_SAMPLER:-parentbased_traceidratio}"
export OTEL_TRACES_SAMPLER_ARG="${OTEL_TRACES_SAMPLER_ARG:-0.10}"
export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-none}"
export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-none}"

# resource attributes: コンテナ役割の識別子を必ず含める (既存値の後ろに追記)
DEFAULT_ATTRS="container.role=front"
if [[ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]]; then
  case "${OTEL_RESOURCE_ATTRIBUTES}" in
    *container.role=*) : ;;  # 既に設定済みなら何もしない
    *) export OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES},${DEFAULT_ATTRS}" ;;
  esac
else
  export OTEL_RESOURCE_ATTRIBUTES="${DEFAULT_ATTRS}"
fi

log "OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}"
log "OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT} (${OTEL_EXPORTER_OTLP_PROTOCOL})"
log "OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES}"

# --- -javaagent の安全な追加 (二重登録防止) ----------------------------------
JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-}"
if [[ "${JAVA_TOOL_OPTIONS}" == *"-javaagent"* ]]; then
  log "WARN: JAVA_TOOL_OPTIONS already contains -javaagent; skip adding ADOT agent"
else
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+${JAVA_TOOL_OPTIONS} }-javaagent:${ADOT_AGENT_JAR}"
fi

# --- 自己署名 CA / 自己署名証明書を JVM トラストストアへ取り込む ---------------
# 目的: HTTPS を要求する REST API (secure-api / ALB HTTPS リスナー) の
#       サーバ証明書を、アプリコードを無改変のまま検証できるようにする。
#
# なぜ cacerts を「コピーしてから」使うのか:
#   コンテナは jboss (UID 185) で動くため ${JAVA_HOME}/lib/security/cacerts を
#   直接書き換えられない (root 所有)。書き込み可能な場所へコピーして CA を足し、
#   javax.net.ssl.trustStore でその位置を JVM に教える。
#   コピー元は JDK 同梱の cacerts なので、パブリック CA の信頼はそのまま残る
#   (= 自己署名 CA を「追加」するだけで、既存の信頼を壊さない)。
#
# なぜ JAVA_TOOL_OPTIONS か:
#   JBoss の JAVA_OPTS_APPEND でも渡せるが、JAVA_TOOL_OPTIONS は JVM が必ず
#   解釈するため、jboss-cli など補助 JVM からも同じトラストストアが使われる。
#
# 取り込む証明書: ${PKI_TRUST_DIR}/*.crt (pki-init が発行し named volume で共有)
#   10-local-test-root-ca.crt          ルート CA         ┐ この 2 枚を入れると
#   20-local-test-intermediate-ca.crt  中間 CA           ┘ CA 発行の証明書を全て信頼
#   30-alb-selfsigned.crt              ALB の自己署名証明書 (その 1 枚だけを信頼)
# ファイル名 (拡張子を除く) がそのまま keytool の alias になる。
PKI_TRUST_DIR="${PKI_TRUST_DIR:-/mnt/pki/trust}"
JVM_TRUSTSTORE_DIR="${JVM_TRUSTSTORE_DIR:-/tmp/pki}"
JVM_TRUSTSTORE_FILE="${JVM_TRUSTSTORE_FILE:-${JVM_TRUSTSTORE_DIR}/cacerts}"
# コピー元 cacerts のパスワード (JDK 既定値。テスト環境のため既定のまま使う)
JVM_TRUSTSTORE_PASSWORD="${JVM_TRUSTSTORE_PASSWORD:-changeit}"
# true にすると取り込みに失敗した時点で起動を中止する (既定は警告のみで続行)
TRUSTSTORE_IMPORT_REQUIRED="${TRUSTSTORE_IMPORT_REQUIRED:-false}"

# JDK 同梱 cacerts の場所を探す (ディストリビューションによって位置が異なる)
find_source_cacerts() {
  local java_bin candidates=()
  [[ -n "${JAVA_HOME:-}" ]] && candidates+=("${JAVA_HOME}/lib/security/cacerts")
  candidates+=("/etc/pki/java/cacerts")
  if java_bin="$(command -v java 2>/dev/null)"; then
    candidates+=("$(dirname "$(dirname "$(readlink -f "${java_bin}")")")/lib/security/cacerts")
  fi
  local c
  for c in "${candidates[@]}"; do
    [[ -r "${c}" ]] && { echo "${c}"; return 0; }
  done
  return 1
}

import_trusted_certs() {
  local src dst imported=0 failed=0 f alias

  # 取り込む証明書が無ければ何もしない (pki 未マウントの環境でも起動できるように)
  if [[ ! -d "${PKI_TRUST_DIR}" ]] || ! compgen -G "${PKI_TRUST_DIR}/*.crt" >/dev/null; then
    log "truststore: ${PKI_TRUST_DIR} に *.crt が無いため取り込みをスキップします"
    return 0
  fi

  if ! command -v keytool >/dev/null 2>&1; then
    log "WARN: keytool が見つからないためトラストストアへの取り込みをスキップします"
    [[ "${TRUSTSTORE_IMPORT_REQUIRED}" == "true" ]] && fail "keytool not found"
    return 0
  fi

  if ! src="$(find_source_cacerts)"; then
    log "WARN: JDK 同梱の cacerts が見つかりません"
    [[ "${TRUSTSTORE_IMPORT_REQUIRED}" == "true" ]] && fail "source cacerts not found"
    return 0
  fi

  dst="${JVM_TRUSTSTORE_FILE}"
  mkdir -p "$(dirname "${dst}")"
  # 毎起動でコピーし直す = alias 重複エラーが起きず、常に最新の CA が反映される
  cp -f "${src}" "${dst}"
  chmod 0600 "${dst}"
  log "truststore: ${src} → ${dst} にコピーしました"

  for f in "${PKI_TRUST_DIR}"/*.crt; do
    [[ -e "${f}" ]] || continue
    alias="$(basename "${f}" .crt)"
    if keytool -importcert -noprompt -trustcacerts \
         -alias "${alias}" -file "${f}" \
         -keystore "${dst}" -storepass "${JVM_TRUSTSTORE_PASSWORD}" >/dev/null 2>&1; then
      log "truststore: imported alias=${alias} subject=$(openssl x509 -in "${f}" -noout -subject 2>/dev/null | sed 's/^subject=//' || echo '(openssl 無し)')"
      imported=$((imported + 1))
    else
      log "WARN: truststore import failed: alias=${alias} file=${f}"
      failed=$((failed + 1))
    fi
  done

  if (( imported == 0 )); then
    log "WARN: 1 件も取り込めませんでした (HTTPS 呼び出しは失敗します)"
    [[ "${TRUSTSTORE_IMPORT_REQUIRED}" == "true" ]] && fail "no certificate imported into truststore"
    return 0
  fi

  # JVM 全体へトラストストアを指定する。
  # trustStoreType は指定しない (JKS/PKCS12 は JDK が自動判別するため、
  # 明示するとコピー元の形式が変わったときに読めなくなる)。
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+${JAVA_TOOL_OPTIONS} }-Djavax.net.ssl.trustStore=${dst} -Djavax.net.ssl.trustStorePassword=${JVM_TRUSTSTORE_PASSWORD}"
  log "truststore: ready (imported=${imported} failed=${failed}) path=${dst}"
}

import_trusted_certs

# --- DB への TLS 設定と JVM トラストストアの整合性チェック --------------------
# XA データソースの SslMode は ${env.DB_SSL_MODE} (既定 VERIFY_IDENTITY)。
# VERIFY_CA / VERIFY_IDENTITY は「サーバ証明書を発行した CA が JVM トラストストア
# にある」ことが前提で、無い場合はプール初期化時に
#   PKIX path building failed / unable to find valid certification path
# という一見 DB と無関係なエラーになり原因の切り分けに時間がかかる。
# ここで前もって警告を出しておく。
#   ローカル … pki-init のルート/中間 CA (上の import_trusted_certs で取り込み済み)
#   本番     … Amazon RDS の CA バンドル (global-bundle.pem) を ${PKI_TRUST_DIR} へ
#              配置するか、イメージへ焼き込んでおく
DB_SSL_MODE="${DB_SSL_MODE:-VERIFY_IDENTITY}"
if [[ "${DB_SSL_MODE}" == VERIFY_* && "${JAVA_TOOL_OPTIONS}" != *"-Djavax.net.ssl.trustStore="* ]]; then
  log "WARN: DB_SSL_MODE=${DB_SSL_MODE} だがトラストストアを構成できていません"
  log "WARN: DB のサーバ証明書を発行した CA が JDK 同梱 cacerts に無いと XA 接続に失敗します"
  log "WARN: ${PKI_TRUST_DIR} に CA 証明書を置くか、DB_SSL_MODE=REQUIRED を指定してください"
fi
log "DB connection: host=${DB_HOST} port=${DB_PORT} db=${DB_NAME} sslMode=${DB_SSL_MODE}"

log "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS}"

# --- ヒープ等の追加 JVM オプション (JBoss 標準の JAVA_OPTS_APPEND を利用) -----
export JAVA_OPTS_APPEND="${JAVA_OPTS_APPEND:-}"

# --- XA リカバリ用ノード ID (未指定時はコンテナホスト名で一意化) --------------
TX_NODE_ID="${TX_NODE_ID:-front-$(hostname)}"
log "transaction node-identifier=${TX_NODE_ID}"

EFS_LOG_DIR="${EFS_LOG_DIR:-/mnt/logs}"
EFS_DATA_DIR="${EFS_DATA_DIR:-/mnt/data}"

# --- EFS 上のサブディレクトリを group-writable (setgid) で用意 -----------------
# 背景: /mnt/logs, /mnt/data は efs-mock が mode 2775 (setgid) で初期化済みだが、
# その配下へ mkdir する際、新規ディレクトリのパーミッションはプロセスの umask で決まる。
# 既定の umask 0022 では group の write ビットが落ち (setgid だけ親から継承されて 2755
# 相当になる)、GID 6302 を共有する別プロセス/別コンテナが、作成済みディレクトリの配下へ
# さらにディレクトリ/ファイルを作成できなくなる。
# 対処: umask を 0002 にしてから作成する。この umask は exec 先の JBoss にも継承されるため、
# JBoss が実行時に /mnt/logs 配下へ作るディレクトリ/ファイルも group-writable になる。
# 併せて生成済みディレクトリへ明示的に mode 2775 を付与し、冪等に修復する。
umask 0002

# setgid + group-write (2775) を保証しつつ冪等にディレクトリを作成する
ensure_shared_dir() {
  local dir="$1"
  if ! mkdir -p "${dir}" 2>/dev/null; then
    log "WARN: cannot create ${dir} (uid=$(id -u) groups=$(id -G))"
    return 0
  fi
  # mode の強制は所有者のみ可能。別ユーザ所有なら既存権限を尊重し警告に留める
  chmod 2775 "${dir}" 2>/dev/null \
    || log "WARN: cannot chmod 2775 ${dir} (owner=$(stat -c '%U:%G' "${dir}" 2>/dev/null))"
}

# 役割別サブディレクトリ (例: /mnt/logs/front/logs)。環境変数で上書き可能
EFS_ROLE_LOG_DIR="${EFS_ROLE_LOG_DIR:-${EFS_LOG_DIR}/front/logs}"
EFS_ROLE_DATA_DIR="${EFS_ROLE_DATA_DIR:-${EFS_DATA_DIR}/front}"
if [[ -d "${EFS_LOG_DIR}" ]]; then
  # 中間ディレクトリ (/mnt/logs/front) も含め各階層を 2775 で確実に整える
  ensure_shared_dir "${EFS_LOG_DIR}/front"
  ensure_shared_dir "${EFS_ROLE_LOG_DIR}"
  log "EFS role log dir ready: ${EFS_ROLE_LOG_DIR} (mode=$(stat -c '%a %U:%G' "${EFS_ROLE_LOG_DIR}" 2>/dev/null))"
fi
if [[ -d "${EFS_DATA_DIR}" ]]; then
  ensure_shared_dir "${EFS_ROLE_DATA_DIR}"
  log "EFS role data dir ready: ${EFS_ROLE_DATA_DIR} (mode=$(stat -c '%a %U:%G' "${EFS_ROLE_DATA_DIR}" 2>/dev/null))"
fi

# --- EFS マウントポイント (/mnt/logs, /mnt/data) への書き込み検証 --------------
# ECS では EFS (アクセスポイント不使用)、ローカル compose では efs-mock が初期化した
# named volume がマウントされる想定。マウントされていない環境では検証をスキップする。
# /mnt/logs への書き込みは cwagent のファイル検知トリガーも兼ねる。
EFS_MARKER="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [app-front] startup uid=$(id -u) gid=$(id -g) groups=$(id -G) host=$(hostname)"
if [[ -d "${EFS_LOG_DIR}" ]]; then
  if echo "${EFS_MARKER}" >> "${EFS_LOG_DIR}/app-front.log" 2>/dev/null; then
    log "EFS write check OK: ${EFS_LOG_DIR}/app-front.log"
  else
    log "WARN: cannot write to ${EFS_LOG_DIR} (uid=$(id -u) groups=$(id -G))"
  fi
fi
if [[ -d "${EFS_DATA_DIR}" ]]; then
  if echo "${EFS_MARKER}" >> "${EFS_DATA_DIR}/app-front-data.txt" 2>/dev/null; then
    log "EFS write check OK: ${EFS_DATA_DIR}/app-front-data.txt"
  else
    log "WARN: cannot write to ${EFS_DATA_DIR} (uid=$(id -u) groups=$(id -G))"
  fi
fi

# --- JBoss EAP を exec で起動 (シグナルを直接受けるため exec 必須) ------------
exec "${JBOSS_HOME}/bin/standalone.sh" \
  -b 0.0.0.0 \
  -bmanagement 127.0.0.1 \
  -Djboss.tx.node.id="${TX_NODE_ID}"
