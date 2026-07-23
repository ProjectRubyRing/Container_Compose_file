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

# --- EFS マウントポイント (/mnt/logs, /mnt/data) への書き込み検証 --------------
# ECS では EFS (アクセスポイント不使用)、ローカル compose では efs-mock が初期化した
# named volume がマウントされる想定。マウントされていない環境では検証をスキップする。
# /mnt/logs への書き込みは cwagent のファイル検知トリガーも兼ねる。
EFS_LOG_DIR="${EFS_LOG_DIR:-/mnt/logs}"
EFS_DATA_DIR="${EFS_DATA_DIR:-/mnt/data}"
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

# --- 読み取り専用ルートFS (read_only: true) への対応 --------------------------
# JBoss EAP は起動時に ${JBOSS_HOME}/standalone 配下 (data/tmp/log/configuration/
# deployments) へ書き込むため、コンテナのルートFSが読み取り専用だと起動できない。
# /mnt/logs, /mnt/data は書き込み可能な named volume なので影響を受けない
# (「マウント先だから書ける」は正しい) が、standalone 配下は別に書き込み先が要る。
# ルートFSが読み取り専用のとき (= standalone に書けないとき) のみ、書き込み可能な
# tmpfs へ standalone を複製し JBOSS_BASE_DIR をそこへ向ける。standalone.sh は
# この環境変数を尊重し、data/tmp/log/configuration/deployments・ブートログの
# すべてを複製先 (書き込み可能) へ解決する。
# ルートFSが書き込み可能な環境 (ECS taskdef は readOnlyRootFilesystem 未設定) では
# 何もせず従来どおり ${JBOSS_HOME}/standalone を使う (挙動は不変)。
if ( : > "${JBOSS_HOME}/standalone/.writable-probe" ) 2>/dev/null; then
  rm -f "${JBOSS_HOME}/standalone/.writable-probe"
  log "root filesystem is writable; using ${JBOSS_HOME}/standalone as-is"
else
  JBOSS_BASE_DIR="${JBOSS_BASE_DIR:-/tmp/jboss/standalone}"
  log "root filesystem is read-only; relocating writable JBoss server dir to ${JBOSS_BASE_DIR}"
  mkdir -p "${JBOSS_BASE_DIR}"
  cp -a "${JBOSS_HOME}/standalone/." "${JBOSS_BASE_DIR}/"
  export JBOSS_BASE_DIR
fi

exec "${JBOSS_HOME}/bin/standalone.sh" \
  -b 0.0.0.0 \
  -bmanagement 127.0.0.1 \
  -Djboss.socket.binding.port-offset="${PORT_OFFSET}" \
  -Djboss.tx.node.id="${TX_NODE_ID}"
