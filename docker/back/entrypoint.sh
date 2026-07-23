#!/usr/bin/env bash
# =============================================================================
# バックコンテナ用 Entrypoint
# - フロントとの差分:
#   * OTEL_SERVICE_NAME デフォルトが app-back / container.role=back
#   * ECS awsvpc ではフロントと同一ネットワーク名前空間のため、
#     ポート衝突回避に jboss.socket.binding.port-offset (デフォルト 100 → HTTP 8180)
#   * SVF 帳票サーバ (ALB 経由 REST) 向け環境変数の検証
# =============================================================================
set -euo pipefail

log()  { echo "[entrypoint][back] $*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

: "${JBOSS_HOME:?JBOSS_HOME must be set (e.g. /opt/server)}"
[[ -x "${JBOSS_HOME}/bin/standalone.sh" ]] || fail "standalone.sh not found under ${JBOSS_HOME}/bin"

ADOT_AGENT_JAR="${ADOT_AGENT_JAR:-/opt/adot/aws-opentelemetry-agent.jar}"
[[ -f "${ADOT_AGENT_JAR}" ]] || fail "ADOT Java Agent not found: ${ADOT_AGENT_JAR}"

for v in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD; do
  [[ -n "${!v:-}" ]] || fail "required environment variable ${v} is not set"
done
[[ -n "${SVF_BASE_URL:-}" ]] || log "WARN: SVF_BASE_URL is not set; report REST calls will fail"

# --- OTel 設定 ----------------------------------------------------------------
export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-app-back}"
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}"
export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"
export OTEL_PROPAGATORS="${OTEL_PROPAGATORS:-xray,tracecontext,baggage}"
export OTEL_TRACES_SAMPLER="${OTEL_TRACES_SAMPLER:-parentbased_traceidratio}"
export OTEL_TRACES_SAMPLER_ARG="${OTEL_TRACES_SAMPLER_ARG:-0.10}"
export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-none}"
export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-none}"

DEFAULT_ATTRS="container.role=back"
if [[ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]]; then
  case "${OTEL_RESOURCE_ATTRIBUTES}" in
    *container.role=*) : ;;
    *) export OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES},${DEFAULT_ATTRS}" ;;
  esac
else
  export OTEL_RESOURCE_ATTRIBUTES="${DEFAULT_ATTRS}"
fi

log "OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}"
log "OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT} (${OTEL_EXPORTER_OTLP_PROTOCOL})"
log "OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES}"

# --- -javaagent の安全な追加 ---------------------------------------------------
JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-}"
if [[ "${JAVA_TOOL_OPTIONS}" == *"-javaagent"* ]]; then
  log "WARN: JAVA_TOOL_OPTIONS already contains -javaagent; skip adding ADOT agent"
else
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+${JAVA_TOOL_OPTIONS} }-javaagent:${ADOT_AGENT_JAR}"
fi
log "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS}"

export JAVA_OPTS_APPEND="${JAVA_OPTS_APPEND:-}"

# --- ポートオフセット (front:8080 / back:8180) ---------------------------------
PORT_OFFSET="${PORT_OFFSET:-100}"
log "jboss.socket.binding.port-offset=${PORT_OFFSET} (HTTP listens on $((8080 + PORT_OFFSET)))"

TX_NODE_ID="${TX_NODE_ID:-back-$(hostname)}"
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

# 役割別サブディレクトリ (例: /mnt/logs/back/logs)。環境変数で上書き可能
EFS_ROLE_LOG_DIR="${EFS_ROLE_LOG_DIR:-${EFS_LOG_DIR}/back/logs}"
EFS_ROLE_DATA_DIR="${EFS_ROLE_DATA_DIR:-${EFS_DATA_DIR}/back}"
if [[ -d "${EFS_LOG_DIR}" ]]; then
  # 中間ディレクトリ (/mnt/logs/back) も含め各階層を 2775 で確実に整える
  ensure_shared_dir "${EFS_LOG_DIR}/back"
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
EFS_MARKER="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [app-back] startup uid=$(id -u) gid=$(id -g) groups=$(id -G) host=$(hostname)"
if [[ -d "${EFS_LOG_DIR}" ]]; then
  if echo "${EFS_MARKER}" >> "${EFS_LOG_DIR}/app-back.log" 2>/dev/null; then
    log "EFS write check OK: ${EFS_LOG_DIR}/app-back.log"
  else
    log "WARN: cannot write to ${EFS_LOG_DIR} (uid=$(id -u) groups=$(id -G))"
  fi
fi
if [[ -d "${EFS_DATA_DIR}" ]]; then
  if echo "${EFS_MARKER}" >> "${EFS_DATA_DIR}/app-back-data.txt" 2>/dev/null; then
    log "EFS write check OK: ${EFS_DATA_DIR}/app-back-data.txt"
  else
    log "WARN: cannot write to ${EFS_DATA_DIR} (uid=$(id -u) groups=$(id -G))"
  fi
fi

exec "${JBOSS_HOME}/bin/standalone.sh" \
  -b 0.0.0.0 \
  -bmanagement 127.0.0.1 \
  -Djboss.socket.binding.port-offset="${PORT_OFFSET}" \
  -Djboss.tx.node.id="${TX_NODE_ID}"
