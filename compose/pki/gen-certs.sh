#!/bin/sh
# =============================================================================
# 自己署名 PKI 一式の発行 (テスト環境専用)
# ---------------------------------------------------------------------------
# 実 AWS との対応:
#   ルート CA / 中間 CA        → AWS Private CA (ACM PCA) もしくは社内 CA
#                                 (DB 経路については Amazon RDS Root CA → リージョン中間 CA)
#   secure-api のサーバ証明書   → 中間 CA が発行したサーバ証明書 (CA 発行パターン)
#   alb/ca-issued のサーバ証明書 → ACM が発行 / ACM にインポートした CA 発行証明書
#   alb/selfsigned のサーバ証明書 → 自己署名証明書をそのまま ALB に適用するパターン
#   rds-proxy のサーバ証明書     → RDS Proxy エンドポイントが提示する証明書
#                                 (実 AWS では rds-ca-rsa2048-g1 等、Amazon RDS CA 発行)
#
# 「JVM トラストストアに何をインポートするか」の 2 パターンを同時に検証できるよう、
# 意図的に 2 種類の信頼形態を用意している:
#   (A) 中間 CA 証明書をインポート  → その CA が発行した全証明書を信頼 (secure-api, alb/ca-issued)
#   (B) 自己署名証明書そのものをインポート → その 1 枚だけを信頼 (alb/selfsigned)
#
# 出力レイアウト (${PKI_ROOT}, 既定 /pki):
#   ca/root-ca.crt|key            ルート CA (自己署名)
#   ca/intermediate-ca.crt|key    中間 CA (ルート CA が署名)
#   ca/ca-chain.crt               中間 + ルート (クライアント検証用の CA バンドル)
#   secure-api/server.crt|key     secure-api のサーバ証明書 (中間 CA 発行)
#   secure-api/fullchain.crt      サーバ証明書 + 中間 CA (サーバが提示するチェーン)
#   secure-api/server.p12         WireMock (Jetty) 用 PKCS#12 キーストア
#   alb/ca-issued/*               ALB 用 (中間 CA 発行) — ACM 発行相当
#   alb/selfsigned/*              ALB 用 (自己署名リーフ) — 自己証明書適用パターン
#   rds-proxy/server.crt|key      MySQL (RDS Proxy 相当) のサーバ証明書 (中間 CA 発行)
#   rds-proxy/fullchain.crt       サーバ証明書 + 中間 CA (mysqld が提示するチェーン)
#   trust/*.crt                   front/back の JVM トラストストアへ入れる証明書
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

# SAN。compose のサービス名で名前解決するため DNS 名にサービス名を必ず含める
SECURE_API_SAN="${PKI_SECURE_API_SAN:-DNS:secure-api,DNS:secure-api.local,DNS:localhost,IP:127.0.0.1}"
ALB_SAN="${PKI_ALB_SAN:-DNS:alb,DNS:alb.local,DNS:alb.example.internal,DNS:localhost,IP:127.0.0.1}"
# DB 経路。front/back は DB_HOST=mysql で接続するため DNS:mysql が必須。
# 実 AWS ではここが RDS Proxy のエンドポイント FQDN
# (例: <proxy>.proxy-<id>.<region>.rds.amazonaws.com) になる。
RDS_PROXY_SAN="${PKI_RDS_PROXY_SAN:-DNS:mysql,DNS:mysql.local,DNS:localhost,IP:127.0.0.1}"

log() { echo "[pki-init] $*" >&2; }

MARKER="${PKI_ROOT}/.pki-ready"
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

  # -------------------------------------------------------------------------
  # 1) ルート CA (自己署名)
  # -------------------------------------------------------------------------
  log "1/7 ルート CA を生成 (自己署名, ${DAYS_CA} 日)"
  openssl req -x509 -newkey "rsa:${KEY_BITS}" -sha256 -days "${DAYS_CA}" -nodes \
    -keyout "${PKI_ROOT}/ca/root-ca.key" \
    -out    "${PKI_ROOT}/ca/root-ca.crt" \
    -subj   "${SUBJ_BASE}/CN=Local Test Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1

  # -------------------------------------------------------------------------
  # 2) 中間 CA (ルート CA が署名)
  # -------------------------------------------------------------------------
  log "2/7 中間 CA を生成 (ルート CA が署名, ${DAYS_CA} 日)"
  cat > "${TMP}/intermediate.ext" <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
EOF
  openssl req -new -newkey "rsa:${KEY_BITS}" -nodes \
    -keyout "${PKI_ROOT}/ca/intermediate-ca.key" \
    -out    "${TMP}/intermediate-ca.csr" \
    -subj   "${SUBJ_BASE}/CN=Local Test Intermediate CA" >/dev/null 2>&1
  openssl x509 -req -in "${TMP}/intermediate-ca.csr" \
    -CA "${PKI_ROOT}/ca/root-ca.crt" -CAkey "${PKI_ROOT}/ca/root-ca.key" -CAcreateserial \
    -days "${DAYS_CA}" -sha256 -extfile "${TMP}/intermediate.ext" \
    -out "${PKI_ROOT}/ca/intermediate-ca.crt" >/dev/null 2>&1

  # クライアント (curl / nginx proxy_ssl) が検証に使う CA バンドル。
  # 順序はリーフに近い方から: 中間 → ルート
  cat "${PKI_ROOT}/ca/intermediate-ca.crt" "${PKI_ROOT}/ca/root-ca.crt" \
    > "${PKI_ROOT}/ca/ca-chain.crt"

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

  # 中間 CA でサーバ証明書を発行する
  issue_from_intermediate() {  # $1=出力ディレクトリ  $2=CN  $3=SAN
    _dir="$1"; _cn="$2"; _san="$3"
    make_server_ext "${TMP}/server.ext" "${_san}"
    openssl req -new -newkey "rsa:${KEY_BITS}" -nodes \
      -keyout "${_dir}/server.key" -out "${TMP}/server.csr" \
      -subj "${SUBJ_BASE}/CN=${_cn}" >/dev/null 2>&1
    openssl x509 -req -in "${TMP}/server.csr" \
      -CA "${PKI_ROOT}/ca/intermediate-ca.crt" -CAkey "${PKI_ROOT}/ca/intermediate-ca.key" \
      -CAcreateserial -days "${DAYS_LEAF}" -sha256 -extfile "${TMP}/server.ext" \
      -out "${_dir}/server.crt" >/dev/null 2>&1
    # サーバが提示するチェーン (リーフ + 中間)。ルートはクライアント側が持つ想定
    cat "${_dir}/server.crt" "${PKI_ROOT}/ca/intermediate-ca.crt" > "${_dir}/fullchain.crt"
  }

  # -------------------------------------------------------------------------
  # 3) secure-api のサーバ証明書 (中間 CA 発行)
  # -------------------------------------------------------------------------
  log "3/7 secure-api のサーバ証明書を発行 (中間 CA 発行, SAN=${SECURE_API_SAN})"
  issue_from_intermediate "${PKI_ROOT}/secure-api" "secure-api" "${SECURE_API_SAN}"

  # WireMock (Jetty) は JKS/PKCS#12 キーストアを要求するため PKCS#12 に固める。
  # -certfile で中間 CA を同梱し、サーバがチェーンを提示できるようにする。
  openssl pkcs12 -export \
    -inkey    "${PKI_ROOT}/secure-api/server.key" \
    -in       "${PKI_ROOT}/secure-api/server.crt" \
    -certfile "${PKI_ROOT}/ca/intermediate-ca.crt" \
    -name     "secure-api" \
    -out      "${PKI_ROOT}/secure-api/server.p12" \
    -passout  "pass:${KEYSTORE_PASSWORD}" >/dev/null 2>&1

  # -------------------------------------------------------------------------
  # 4) ALB のサーバ証明書 (パターン A: 中間 CA 発行 = ACM 発行相当)
  # -------------------------------------------------------------------------
  log "4/7 ALB のサーバ証明書 (中間 CA 発行) を発行 SAN=${ALB_SAN}"
  issue_from_intermediate "${PKI_ROOT}/alb/ca-issued" "alb.example.internal" "${ALB_SAN}"

  # -------------------------------------------------------------------------
  # 5) ALB のサーバ証明書 (パターン B: 自己署名リーフ = 自己証明書をそのまま適用)
  #    CA を介さないため、信頼させるにはこの証明書自体をトラストストアへ入れる。
  # -------------------------------------------------------------------------
  log "5/7 ALB のサーバ証明書 (自己署名) を発行 SAN=${ALB_SAN}"
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
  # 6) MySQL (RDS Proxy 相当) のサーバ証明書 (中間 CA 発行)
  #    コミュニティ版 mysqld は既定で初回起動時に「自己署名の ca.pem + サーバ証明書」を
  #    自動生成する。それだと
  #      [Warning] [MY-010068] CA certificate ca.pem is self signed.
  #    が出るうえ、証明書の CN が MySQL_Server_<version>_Auto_Generated_Server_Certificate
  #    で SAN も無いため sslMode=VERIFY_CA / VERIFY_IDENTITY が成立しない。
  #    本番の RDS Proxy は Amazon RDS CA が発行した証明書を提示するので、
  #    ローカルでも CA 発行の証明書を用意して mysqld に使わせ、挙動をそろえる。
  # -------------------------------------------------------------------------
  log "6/7 MySQL (RDS Proxy 相当) のサーバ証明書を発行 (中間 CA 発行, SAN=${RDS_PROXY_SAN})"
  issue_from_intermediate "${PKI_ROOT}/rds-proxy" "mysql" "${RDS_PROXY_SAN}"

  # -------------------------------------------------------------------------
  # 7) front/back の JVM トラストストアへ入れる証明書を trust/ に集約
  #    ここに置いた *.crt を各コンテナの entrypoint が keytool で取り込む。
  #    ファイル名 (拡張子除く) がそのまま keytool の alias になる。
  # -------------------------------------------------------------------------
  log "7/7 トラストストア投入用の証明書を ${PKI_ROOT}/trust へ配置"
  cp "${PKI_ROOT}/ca/root-ca.crt"              "${PKI_ROOT}/trust/10-local-test-root-ca.crt"
  cp "${PKI_ROOT}/ca/intermediate-ca.crt"      "${PKI_ROOT}/trust/20-local-test-intermediate-ca.crt"
  cp "${PKI_ROOT}/alb/selfsigned/server.crt"   "${PKI_ROOT}/trust/30-alb-selfsigned.crt"

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
for c in "${PKI_ROOT}/ca/root-ca.crt" \
         "${PKI_ROOT}/ca/intermediate-ca.crt" \
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
if openssl verify -CAfile "${PKI_ROOT}/ca/root-ca.crt" \
     -untrusted "${PKI_ROOT}/ca/intermediate-ca.crt" \
     "${PKI_ROOT}/secure-api/server.crt" >/dev/null 2>&1; then
  log "chain verify OK: secure-api/server.crt ← intermediate ← root"
else
  log "ERROR: secure-api のチェーン検証に失敗しました"
  exit 1
fi

# mysqld も起動時に自分のサーバ証明書を ssl_ca で検証する (失敗すると MY-015010/
# MY-015011 の警告が出る) ため、ここで同じ検証を先回りして行っておく。
if openssl verify -CAfile "${PKI_ROOT}/ca/ca-chain.crt" \
     "${PKI_ROOT}/rds-proxy/server.crt" >/dev/null 2>&1; then
  log "chain verify OK: rds-proxy/server.crt ← intermediate ← root"
else
  log "ERROR: rds-proxy (MySQL) のチェーン検証に失敗しました"
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
