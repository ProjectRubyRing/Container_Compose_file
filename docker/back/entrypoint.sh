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

# --- 自己証明書 (cacert.crt) を JDK と JBoss の両トラストストアへ取り込む -------
# 詳細な意図は front/entrypoint.sh の同ブロックのコメントを参照 (両者は同一処理)。
#   - 取り込む証明書は pki-init が named volume で配る ${PKI_TRUST_DIR}/*.crt
#       cacert.crt         ★自己証明書。compose/pki/provided/cacert.crt を置いていれば
#                           ★受領物そのもの★が入る (無ければ pki-init が自動発行したもの)
#       alb-selfsigned.crt  ALB に自己署名リーフを適用したとき用
#       local-test-ca.crt   受領 cacert.crt に秘密鍵が無い場合だけ配られる、
#                           サーバ証明書発行専用のローカル CA (PKI_TRUST_LOCAL_CA=1 のとき)
#   - 取り込み先 1 (JDK): jboss(185) は ${JAVA_HOME}/lib/security/cacerts を
#     書き換えられないため、書き込み可能な場所へコピーしてから追加し、
#     -Djavax.net.ssl.trustStore で JVM に位置を教える (パブリック CA も残る)
#   - 取り込み先 2 (JBoss): ${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12
#     を毎起動で作り直す。cli/elytron-truststore.cli の key-store=appTrustStore が
#     このファイルを参照する (自己証明書だけを信頼する専用ストア)
PKI_TRUST_DIR="${PKI_TRUST_DIR:-/mnt/pki/trust}"
JVM_TRUSTSTORE_DIR="${JVM_TRUSTSTORE_DIR:-/tmp/pki}"
JVM_TRUSTSTORE_FILE="${JVM_TRUSTSTORE_FILE:-${JVM_TRUSTSTORE_DIR}/cacerts}"
JVM_TRUSTSTORE_PASSWORD="${JVM_TRUSTSTORE_PASSWORD:-changeit}"
JBOSS_TRUSTSTORE_FILE="${JBOSS_TRUSTSTORE_FILE:-${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12}"
JBOSS_TRUSTSTORE_PASSWORD="${JBOSS_TRUSTSTORE_PASSWORD:-changeit}"
TRUSTSTORE_IMPORT_REQUIRED="${TRUSTSTORE_IMPORT_REQUIRED:-false}"
# ビルド時に build secret (id=cacert) で取り込んだ記録。Dockerfile が書き出す。
# 実行時の取り込みと区別してログに出すためだけに参照する
CACERT_BUILD_MARKER="${CACERT_BUILD_MARKER:-/opt/pki/build-import.txt}"

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

# ${PKI_TRUST_DIR}/*.crt を指定のキーストアへ全て取り込み、件数を標準出力へ返す
# ($1=キーストアパス $2=パスワード $3=ログ用ラベル)
import_certs_into() {
  local store="$1" storepass="$2" label="$3"
  local imported=0 failed=0 f alias subject
  for f in "${PKI_TRUST_DIR}"/*.crt; do
    [[ -e "${f}" ]] || continue
    alias="$(basename "${f}" .crt)"
    if keytool -importcert -noprompt -trustcacerts \
         -alias "${alias}" -file "${f}" \
         -keystore "${store}" -storetype PKCS12 -storepass "${storepass}" >/dev/null 2>&1; then
      subject="$(openssl x509 -in "${f}" -noout -subject 2>/dev/null | sed 's/^subject=//' || echo '(openssl 無し)')"
      log "truststore[${label}]: imported alias=${alias} subject=${subject}"
      imported=$((imported + 1))
    else
      log "WARN: truststore[${label}] import failed: alias=${alias} file=${f}"
      failed=$((failed + 1))
    fi
  done
  if (( failed > 0 )); then
    log "truststore[${label}]: failed=${failed}"
  fi
  echo "${imported}"
}

import_trusted_certs() {
  local src dst imported=0

  # ビルド時に build secret (id=cacert) で取り込み済みなら、その記録を表示する。
  # 記録があれば JDK 同梱 cacerts と jboss-truststore.p12 に焼き込み済みという意味
  if [[ -f "${CACERT_BUILD_MARKER}" ]]; then
    log "truststore[build]: ビルド時に cacert.crt を取り込み済み (build secret 経由)"
    while IFS= read -r line; do log "truststore[build]:   ${line}"; done < "${CACERT_BUILD_MARKER}"
  fi

  # ここで return するため、ビルド時に焼き込んだトラストストアは温存される
  # (この下の JBoss 側ストア再生成は「実行時に配る証明書がある」ときだけ走る)
  if [[ ! -d "${PKI_TRUST_DIR}" ]] || ! compgen -G "${PKI_TRUST_DIR}/*.crt" >/dev/null; then
    log "truststore: ${PKI_TRUST_DIR} に *.crt が無いため取り込みをスキップします"
    if [[ -f "${CACERT_BUILD_MARKER}" ]]; then
      log "truststore: ビルド時取り込み済みのトラストストアをそのまま使用します"
    fi
    return 0
  fi

  if ! command -v keytool >/dev/null 2>&1; then
    log "WARN: keytool が見つからないためトラストストアへの取り込みをスキップします"
    [[ "${TRUSTSTORE_IMPORT_REQUIRED}" == "true" ]] && fail "keytool not found"
    return 0
  fi

  # ---- 1) JDK 同梱 cacerts のコピーへ追加 ------------------------------------
  if ! src="$(find_source_cacerts)"; then
    log "WARN: JDK 同梱の cacerts が見つかりません"
    [[ "${TRUSTSTORE_IMPORT_REQUIRED}" == "true" ]] && fail "source cacerts not found"
  else
    dst="${JVM_TRUSTSTORE_FILE}"
    mkdir -p "$(dirname "${dst}")"
    # 毎起動でコピーし直す = alias 重複エラーが起きず、常に最新の CA が反映される
    cp -f "${src}" "${dst}"
    chmod 0600 "${dst}"
    log "truststore[jdk]: ${src} → ${dst} にコピーしました"

    # コピー元の形式に合わせるため JDK 側は -storetype を渡さない (自動判別)
    local f alias jdk_imported=0
    for f in "${PKI_TRUST_DIR}"/*.crt; do
      [[ -e "${f}" ]] || continue
      alias="$(basename "${f}" .crt)"
      if keytool -importcert -noprompt -trustcacerts \
           -alias "${alias}" -file "${f}" \
           -keystore "${dst}" -storepass "${JVM_TRUSTSTORE_PASSWORD}" >/dev/null 2>&1; then
        log "truststore[jdk]: imported alias=${alias} subject=$(openssl x509 -in "${f}" -noout -subject 2>/dev/null | sed 's/^subject=//' || echo '(openssl 無し)')"
        jdk_imported=$((jdk_imported + 1))
      else
        log "WARN: truststore[jdk] import failed: alias=${alias} file=${f}"
      fi
    done

    if (( jdk_imported > 0 )); then
      export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+${JAVA_TOOL_OPTIONS} }-Djavax.net.ssl.trustStore=${dst} -Djavax.net.ssl.trustStorePassword=${JVM_TRUSTSTORE_PASSWORD}"
      log "truststore[jdk]: ready (imported=${jdk_imported}) path=${dst}"
      imported=$((imported + jdk_imported))
    else
      log "WARN: truststore[jdk] へ 1 件も取り込めませんでした"
    fi
  fi

  # ---- 2) JBoss (Elytron) 用トラストストアを作り直す -------------------------
  local jb="${JBOSS_TRUSTSTORE_FILE}" jb_imported=0
  if mkdir -p "$(dirname "${jb}")" 2>/dev/null && rm -f "${jb}" 2>/dev/null; then
    jb_imported="$(import_certs_into "${jb}" "${JBOSS_TRUSTSTORE_PASSWORD}" "jboss")"
    if (( jb_imported > 0 )); then
      chmod 0600 "${jb}" 2>/dev/null || true
      log "truststore[jboss]: ready (imported=${jb_imported}) path=${jb}"
      log "truststore[jboss]: Elytron key-store=appTrustStore / trust-manager=appTrustManager / client-ssl-context=appClientSslContext が参照します"
      imported=$((imported + jb_imported))
    else
      log "WARN: truststore[jboss] へ 1 件も取り込めませんでした"
    fi
  else
    log "WARN: ${jb} を作成できません (uid=$(id -u) groups=$(id -G))"
  fi

  # tls-probe サーブレットが JBoss 側ストアを直接読めるよう位置を渡す
  export JBOSS_TRUSTSTORE_FILE JBOSS_TRUSTSTORE_PASSWORD

  if (( imported == 0 )); then
    log "WARN: 1 件も取り込めませんでした (HTTPS 呼び出しは失敗します)"
    [[ "${TRUSTSTORE_IMPORT_REQUIRED}" == "true" ]] && fail "no certificate imported into truststore"
  fi

  # 【重要】明示的に 0 を返す (理由は front/entrypoint.sh の同ブロックのコメント参照)。
  # 直前の [[ ]] && fail は条件が偽のとき 1 を返し、set -e 下で起動が落ちてしまう。
  return 0
}

import_trusted_certs

# --- DB への TLS 設定と JVM トラストストアの整合性チェック (front と同一) ------
# VERIFY_CA / VERIFY_IDENTITY は「サーバ証明書を発行した CA が JVM トラストストア
# にある」ことが前提。無い場合は PKIX path building failed で XA 接続が失敗する。
DB_SSL_MODE="${DB_SSL_MODE:-VERIFY_IDENTITY}"
if [[ "${DB_SSL_MODE}" == VERIFY_* && "${JAVA_TOOL_OPTIONS}" != *"-Djavax.net.ssl.trustStore="* ]]; then
  log "WARN: DB_SSL_MODE=${DB_SSL_MODE} だがトラストストアを構成できていません"
  log "WARN: DB のサーバ証明書を発行した CA が JDK 同梱 cacerts に無いと XA 接続に失敗します"
  log "WARN: ${PKI_TRUST_DIR} に CA 証明書を置くか、DB_SSL_MODE=REQUIRED を指定してください"
fi
log "DB connection: host=${DB_HOST} port=${DB_PORT} db=${DB_NAME} sslMode=${DB_SSL_MODE}"

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
