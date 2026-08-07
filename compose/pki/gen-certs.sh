#!/bin/sh
# =============================================================================
# 自己証明書 (自己署名 CA) 一式の発行 (テスト環境専用)
# ---------------------------------------------------------------------------
# 【この構成の考え方】
#   信頼の起点を「自己署名 CA 証明書 1 枚 = cacert.crt」に一本化する。
#   front/back は cacert.crt を JDK と JBoss の 2 つのトラストストアへ取り込み、
#   その 1 枚だけで secure-api / ALB / MySQL のサーバ証明書を検証する。
#   実運用で「社内 CA の自己署名ルート証明書 (cacert.crt) を配布し、
#   keytool で JDK 同梱 cacerts と JBoss のトラストストアへインポートする」
#   運用と同じ形をローカルで再現するのが目的。
#
# 実 AWS との対応:
#   cacert.crt                   → AWS Private CA (ACM PCA) のルート CA もしくは社内 CA
#                                   (DB 経路については Amazon RDS Root CA に相当)
#   secure-api のサーバ証明書     → 上記 CA が発行したサーバ証明書
#   alb/ca-issued のサーバ証明書   → ACM が発行 / ACM にインポートした CA 発行証明書
#   alb/selfsigned のサーバ証明書  → 自己署名リーフをそのまま ALB に適用するパターン
#   rds-proxy のサーバ証明書       → RDS Proxy エンドポイントが提示する証明書
#                                   (実 AWS では rds-ca-rsa2048-g1 等、Amazon RDS CA 発行)
#
# 「JVM トラストストアに何をインポートするか」の 2 パターンを検証できるよう、
# 意図的に 2 種類の信頼形態を用意している:
#   (A) 自己署名 CA 証明書 (cacert.crt) をインポート
#         → その CA が発行した全証明書を信頼 (secure-api / alb/ca-issued / rds-proxy)
#   (B) 自己署名リーフ証明書そのものをインポート
#         → その 1 枚だけを信頼 (alb/selfsigned)
#
# 出力レイアウト (${PKI_ROOT}, 既定 /pki):
#   ca/cacert.crt|key             ★自己署名 CA (唯一のトラストアンカー)
#   secure-api/server.crt|key     secure-api のサーバ証明書 (cacert 発行)
#   secure-api/fullchain.crt      サーバ証明書 + cacert (サーバが提示するチェーン)
#   secure-api/server.p12         WireMock (Jetty) 用 PKCS#12 キーストア
#   alb/ca-issued/*               ALB 用 (cacert 発行) — ACM 発行相当
#   alb/selfsigned/*              ALB 用 (自己署名リーフ) — 自己証明書適用パターン
#   rds-proxy/server.crt|key      MySQL (RDS Proxy 相当) のサーバ証明書 (cacert 発行)
#   rds-proxy/fullchain.crt       サーバ証明書 + cacert (mysqld が提示するチェーン)
#   trust/cacert.crt              ★front/back の JDK / JBoss トラストストアへ入れる本命
#   trust/alb-selfsigned.crt      ALB 自己署名リーフを使うとき用 (パターン B)
#   .pki-ready                    生成完了マーカー (healthcheck が参照)
#
# 注意: テスト環境専用のため秘密鍵はパスフレーズ無し・mode 0644 で配置する
#       (コンテナごとに実行ユーザが違うため。本番でこの構成にしないこと)。
# =============================================================================
set -eu

PKI_ROOT="${PKI_ROOT:-/pki}"
DAYS_CA="${PKI_DAYS_CA:-3650}"
DAYS_LEAF="${PKI_DAYS_LEAF:-825}"
KEY_BITS="${PKI_KEY_BITS:-2048}"
KEYSTORE_PASSWORD="${PKI_KEYSTORE_PASSWORD:-changeit}"
FORCE="${PKI_FORCE_REGENERATE:-0}"

# 証明書のサブジェクト (テスト用)
SUBJ_BASE="${PKI_SUBJ_BASE:-/C=JP/ST=Tokyo/L=Chiyoda/O=Local Test Org/OU=Local Test PKI}"
# 自己証明書 (CA) の CN。front/back のトラストストア一覧でこの名前が見える
CA_CN="${PKI_CA_CN:-Local Test Self-Signed CA}"

# SAN。compose のサービス名で名前解決するため DNS 名にサービス名を必ず含める
SECURE_API_SAN="${PKI_SECURE_API_SAN:-DNS:secure-api,DNS:secure-api.local,DNS:localhost,IP:127.0.0.1}"
ALB_SAN="${PKI_ALB_SAN:-DNS:alb,DNS:alb.local,DNS:alb.example.internal,DNS:localhost,IP:127.0.0.1}"
# DB 経路。front/back は DB_HOST=mysql で接続するため DNS:mysql が必須。
# 実 AWS ではここが RDS Proxy のエンドポイント FQDN
# (例: <proxy>.proxy-<id>.<region>.rds.amazonaws.com) になる。
RDS_PROXY_SAN="${PKI_RDS_PROXY_SAN:-DNS:mysql,DNS:mysql.local,DNS:localhost,IP:127.0.0.1}"

log() { echo "[pki-init] $*" >&2; }

MARKER="${PKI_ROOT}/.pki-ready"
CACERT="${PKI_ROOT}/ca/cacert.crt"
CAKEY="${PKI_ROOT}/ca/cacert.key"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- 既に生成済みなら何もしない (冪等) --------------------------------------
if [ -f "${MARKER}" ] && [ "${FORCE}" != "1" ]; then
  log "既存の PKI を再利用します (再生成するには PKI_FORCE_REGENERATE=1)"
  log "generated at: $(cat "${MARKER}")"
else
  [ "${FORCE}" = "1" ] && log "PKI_FORCE_REGENERATE=1 のため PKI を再生成します"

  rm -f "${MARKER}"
  mkdir -p "${PKI_ROOT}/ca" \
           "${PKI_ROOT}/secure-api" \
           "${PKI_ROOT}/alb/ca-issued" \
           "${PKI_ROOT}/alb/selfsigned" \
           "${PKI_ROOT}/rds-proxy" \
           "${PKI_ROOT}/trust"

  # 旧レイアウト (ルート CA + 中間 CA) の残骸が volume に残っていると、
  # 古い CA で発行された証明書やトラストストア用ファイルを拾ってしまう。
  # 再生成時は確実に消す (down -v をしなくても切り替わるようにするため)。
  rm -f "${PKI_ROOT}/ca/root-ca.crt"         "${PKI_ROOT}/ca/root-ca.key" \
        "${PKI_ROOT}/ca/intermediate-ca.crt" "${PKI_ROOT}/ca/intermediate-ca.key" \
        "${PKI_ROOT}/ca/ca-chain.crt"        "${PKI_ROOT}/ca"/*.srl
  rm -f "${PKI_ROOT}/trust"/*.crt

  # -------------------------------------------------------------------------
  # 1) 自己証明書 = 自己署名 CA (cacert.crt)
  #    これ 1 枚がトラストアンカー。front/back はこれを JDK / JBoss の
  #    トラストストアへ取り込み、以降の全サーバ証明書をこれで検証する。
  #    pathlen:0 = この CA は下位 CA を作れない (リーフのみ発行できる)
  # -------------------------------------------------------------------------
  log "1/6 自己証明書 (自己署名 CA) を生成 CN=${CA_CN} (${DAYS_CA} 日)"
  openssl req -x509 -newkey "rsa:${KEY_BITS}" -sha256 -days "${DAYS_CA}" -nodes \
    -keyout "${CAKEY}" \
    -out    "${CACERT}" \
    -subj   "${SUBJ_BASE}/CN=${CA_CN}" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1

  # サーバ証明書用の共通拡張 (serverAuth)。SAN は呼び出し側で差し替える
  make_server_ext() {  # $1=出力パス  $2=SAN
    cat > "$1" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$2
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
  }

  # 自己証明書 (cacert) でサーバ証明書を発行する
  issue_from_cacert() {  # $1=出力ディレクトリ  $2=CN  $3=SAN
    _dir="$1"; _cn="$2"; _san="$3"
    make_server_ext "${TMP}/server.ext" "${_san}"
    openssl req -new -newkey "rsa:${KEY_BITS}" -nodes \
      -keyout "${_dir}/server.key" -out "${TMP}/server.csr" \
      -subj "${SUBJ_BASE}/CN=${_cn}" >/dev/null 2>&1
    openssl x509 -req -in "${TMP}/server.csr" \
      -CA "${CACERT}" -CAkey "${CAKEY}" \
      -CAcreateserial -days "${DAYS_LEAF}" -sha256 -extfile "${TMP}/server.ext" \
      -out "${_dir}/server.crt" >/dev/null 2>&1
    # サーバが提示するチェーン。トラストアンカーが 1 枚なのでリーフ + cacert。
    # (クライアントは cacert を持っている前提なので添付は必須ではないが、
    #  nginx / mysqld / Jetty で設定を共通化するため常に作る)
    cat "${_dir}/server.crt" "${CACERT}" > "${_dir}/fullchain.crt"
  }

  # -------------------------------------------------------------------------
  # 2) secure-api のサーバ証明書 (cacert 発行) — ★接続確認の本命の接続先
  # -------------------------------------------------------------------------
  log "2/6 secure-api のサーバ証明書を発行 (cacert 発行, SAN=${SECURE_API_SAN})"
  issue_from_cacert "${PKI_ROOT}/secure-api" "secure-api" "${SECURE_API_SAN}"

  # WireMock (Jetty) は JKS/PKCS#12 キーストアを要求するため PKCS#12 に固める。
  # -certfile で cacert を同梱し、サーバがチェーンを提示できるようにする。
  openssl pkcs12 -export \
    -inkey    "${PKI_ROOT}/secure-api/server.key" \
    -in       "${PKI_ROOT}/secure-api/server.crt" \
    -certfile "${CACERT}" \
    -name     "secure-api" \
    -out      "${PKI_ROOT}/secure-api/server.p12" \
    -passout  "pass:${KEYSTORE_PASSWORD}" >/dev/null 2>&1

  # -------------------------------------------------------------------------
  # 3) ALB のサーバ証明書 (パターン A: cacert 発行 = ACM 発行相当)
  # -------------------------------------------------------------------------
  log "3/6 ALB のサーバ証明書 (cacert 発行) を発行 SAN=${ALB_SAN}"
  issue_from_cacert "${PKI_ROOT}/alb/ca-issued" "alb.example.internal" "${ALB_SAN}"

  # -------------------------------------------------------------------------
  # 4) ALB のサーバ証明書 (パターン B: 自己署名リーフ = 自己証明書をそのまま適用)
  #    CA を介さないため、信頼させるにはこの証明書自体をトラストストアへ入れる。
  # -------------------------------------------------------------------------
  log "4/6 ALB のサーバ証明書 (自己署名リーフ) を発行 SAN=${ALB_SAN}"
  openssl req -x509 -newkey "rsa:${KEY_BITS}" -sha256 -days "${DAYS_LEAF}" -nodes \
    -keyout "${PKI_ROOT}/alb/selfsigned/server.key" \
    -out    "${PKI_ROOT}/alb/selfsigned/server.crt" \
    -subj   "${SUBJ_BASE}/CN=alb.example.internal" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -addext "subjectAltName=${ALB_SAN}" \
    -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1
  # 自己署名はチェーンが 1 枚なので fullchain = 自分自身 (nginx 設定を共通化するため作る)
  cp "${PKI_ROOT}/alb/selfsigned/server.crt" "${PKI_ROOT}/alb/selfsigned/fullchain.crt"

  # -------------------------------------------------------------------------
  # 5) MySQL (RDS Proxy 相当) のサーバ証明書 (cacert 発行)
  #    コミュニティ版 mysqld は既定で初回起動時に「自己署名の ca.pem + サーバ証明書」を
  #    自動生成する。それだと
  #      [Warning] [MY-010068] CA certificate ca.pem is self signed.
  #    が出るうえ、証明書の CN が MySQL_Server_<version>_Auto_Generated_Server_Certificate
  #    で SAN も無いため sslMode=VERIFY_CA / VERIFY_IDENTITY が成立しない。
  #    本番の RDS Proxy は Amazon RDS CA が発行した証明書を提示するので、
  #    ローカルでも CA 発行の証明書を用意して mysqld に使わせ、挙動をそろえる。
  # -------------------------------------------------------------------------
  log "5/6 MySQL (RDS Proxy 相当) のサーバ証明書を発行 (cacert 発行, SAN=${RDS_PROXY_SAN})"
  issue_from_cacert "${PKI_ROOT}/rds-proxy" "mysql" "${RDS_PROXY_SAN}"

  # -------------------------------------------------------------------------
  # 6) front/back のトラストストアへ入れる証明書を trust/ に集約
  #    ここに置いた *.crt を各コンテナの entrypoint が keytool で
  #    「JDK 同梱 cacerts のコピー」と「JBoss (Elytron) 用トラストストア」の
  #    両方へ取り込む。ファイル名 (拡張子除く) がそのまま keytool の alias になる。
  # -------------------------------------------------------------------------
  log "6/6 トラストストア投入用の証明書を ${PKI_ROOT}/trust へ配置"
  cp "${CACERT}"                               "${PKI_ROOT}/trust/cacert.crt"
  cp "${PKI_ROOT}/alb/selfsigned/server.crt"   "${PKI_ROOT}/trust/alb-selfsigned.crt"

  # 実行ユーザがコンテナごとに異なる (jboss=185 / wiremock=1000 / nginx=root /
  # mysql=999) ため、テスト用途に限り全ファイルを読み取り可能にする
  chmod 0755 "${PKI_ROOT}" "${PKI_ROOT}/ca" "${PKI_ROOT}/secure-api" \
             "${PKI_ROOT}/alb" "${PKI_ROOT}/alb/ca-issued" "${PKI_ROOT}/alb/selfsigned" \
             "${PKI_ROOT}/rds-proxy" "${PKI_ROOT}/trust"
  find "${PKI_ROOT}" -type f -exec chmod 0644 {} +

  date -u '+%Y-%m-%dT%H:%M:%SZ' > "${MARKER}"
  chmod 0644 "${MARKER}"
  log "PKI 生成完了"
fi

# --- 生成結果のサマリを出力 (docker logs pki-init で確認できる) ---------------
log "----------------------------------------------------------------"
for c in "${CACERT}" \
         "${PKI_ROOT}/secure-api/server.crt" \
         "${PKI_ROOT}/alb/ca-issued/server.crt" \
         "${PKI_ROOT}/alb/selfsigned/server.crt" \
         "${PKI_ROOT}/rds-proxy/server.crt"; do
  [ -f "${c}" ] || continue
  log "$(basename "$(dirname "${c}")")/$(basename "${c}")"
  log "    subject: $(openssl x509 -in "${c}" -noout -subject | sed 's/^subject=//')"
  log "    issuer : $(openssl x509 -in "${c}" -noout -issuer  | sed 's/^issuer=//')"
  log "    notAfter: $(openssl x509 -in "${c}" -noout -enddate | sed 's/^notAfter=//')"
done
log "----------------------------------------------------------------"

# チェーン検証 (自己検証。ここで失敗するなら生成がおかしい)
# トラストアンカーは cacert.crt 1 枚なので -untrusted (中間証明書) は不要。
if openssl verify -CAfile "${CACERT}" "${PKI_ROOT}/secure-api/server.crt" >/dev/null 2>&1; then
  log "chain verify OK: secure-api/server.crt ← cacert.crt (自己署名 CA)"
else
  log "ERROR: secure-api のチェーン検証に失敗しました"
  exit 1
fi

# mysqld も起動時に自分のサーバ証明書を ssl_ca で検証する (失敗すると MY-015010/
# MY-015011 の警告が出る) ため、ここで同じ検証を先回りして行っておく。
if openssl verify -CAfile "${CACERT}" "${PKI_ROOT}/rds-proxy/server.crt" >/dev/null 2>&1; then
  log "chain verify OK: rds-proxy/server.crt ← cacert.crt (自己署名 CA)"
else
  log "ERROR: rds-proxy (MySQL) のチェーン検証に失敗しました"
  exit 1
fi

if openssl verify -CAfile "${CACERT}" "${PKI_ROOT}/alb/ca-issued/server.crt" >/dev/null 2>&1; then
  log "chain verify OK: alb/ca-issued/server.crt ← cacert.crt (自己署名 CA)"
else
  log "ERROR: alb/ca-issued のチェーン検証に失敗しました"
  exit 1
fi

# --- 終了方法 ---------------------------------------------------------------
# 既定: 常駐する。compose の depends_on: service_healthy で待たせるには
#       コンテナが running のままである必要があるため。
# --oneshot / PKI_ONESHOT=1: 生成したら終了する。証明書を作り直すときに使う:
#   docker compose run --rm -e PKI_FORCE_REGENERATE=1 pki-init --oneshot
if [ "${1:-}" = "--oneshot" ] || [ "${PKI_ONESHOT:-0}" = "1" ]; then
  log "--oneshot 指定のため終了します"
  exit 0
fi

# 他コンテナが volume 経由で参照するだけなので、常駐して healthy を維持する
exec tail -f /dev/null
