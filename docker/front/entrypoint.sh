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
log "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS}"

# --- ヒープ等の追加 JVM オプション (JBoss 標準の JAVA_OPTS_APPEND を利用) -----
export JAVA_OPTS_APPEND="${JAVA_OPTS_APPEND:-}"

# --- XA リカバリ用ノード ID (未指定時はコンテナホスト名で一意化) --------------
TX_NODE_ID="${TX_NODE_ID:-front-$(hostname)}"
log "transaction node-identifier=${TX_NODE_ID}"

# --- JBoss EAP を exec で起動 (シグナルを直接受けるため exec 必須) ------------
exec "${JBOSS_HOME}/bin/standalone.sh" \
  -b 0.0.0.0 \
  -bmanagement 127.0.0.1 \
  -Djboss.tx.node.id="${TX_NODE_ID}"
