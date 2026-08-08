#!/bin/sh
# =============================================================================
# 自己証明書 (cacert.crt) 一式の配備 (テスト環境専用)
# ---------------------------------------------------------------------------
# 【この構成の考え方】
#   信頼の起点を「自己署名 CA 証明書 1 枚 = cacert.crt」に一本化する。
#   front/back は cacert.crt を JDK と JBoss の 2 つのトラストストアへ取り込み、
#   その 1 枚を起点に secure-api / ALB / MySQL のサーバ証明書を検証する。
#   実運用で「社内 CA の自己署名ルート証明書 (cacert.crt) を配布し、
#   keytool で JDK 同梱 cacerts と JBoss のトラストストアへインポートする」
#   運用と同じ形をローカルで再現するのが目的。
#
# 【cacert.crt の入手方法は 2 通り】★ここがこのスクリプトの中心
#   (1) provided モード … あらかじめ発行済み / 連携された cacert.crt を使う (本命)
#         ${PKI_PROVIDED_DIR} (既定 /provided) に cacert.crt を置くと、
#         このスクリプトは CA を新規発行せず、その受領物をそのまま
#         トラストアンカーとして配備する。
#   (2) generate モード … 従来どおり自己署名 CA をこのスクリプトが発行する
#         受領物が無い場合の既定動作 (後方互換)。
#   PKI_MODE=auto|provided|generate で明示指定もできる (既定 auto = 自動判定)。
#
# 【provided モードで「秘密鍵があるか」により 2 系統に分かれる】
#   受領物に cacert.key が同梱されているかどうかで、サーバ証明書の発行元が変わる。
#
#   (A) cacert.crt + cacert.key の両方あり  → issuer = 受領 CA
#         secure-api / alb(ca-issued) / rds-proxy のサーバ証明書を受領 CA が発行する。
#         front/back が取り込む cacert.crt (受領物) だけで全経路を検証でき、
#         「受領した自己証明書を信頼したから通っている」ことがそのまま示せる。
#
#   (B) cacert.crt のみ (鍵なし)            → issuer = local-test-ca (このスクリプトが生成)
#         鍵の無い CA 証明書は「トラストアンカー」としてしか使えない。
#         受領 CA の署名を作れない以上、ローカルのサーバが受領 CA 発行の
#         サーバ証明書を提示することは暗号的に不可能。
#         そこで役割を次のように分離する:
#           ・受領 cacert.crt  → トラストアンカーとして実際に配布・取り込みする対象
#                                (front/back の JDK/JBoss トラストストアへ入るのは受領物そのもの)
#           ・local-test-ca    → サーバ証明書を発行するためだけのローカル CA
#         これにより「受領物が正しく配布・取り込みされているか」は受領物で検証しつつ、
#         HTTPS / MySQL / ALB といった他の検証項目はブロックされずに実行できる。
#         local-test-ca をトラストストアへ入れるかは PKI_TRUST_LOCAL_CA で選べる:
#           1 (既定) … 入れる。HTTPS 疎通の正常系も通る (alias=local-test-ca)
#           0        … 入れない。信頼するのは受領 cacert.crt 1 枚だけになるため、
#                      secure-api への接続は PKIX で失敗する。
#                      「受領 CA 発行でないサーバ証明書は弾かれる」ことの証明になる。
#         ★後から cacert.key を同じディレクトリへ置けば自動的に (A) へ昇格し、
#           local-test-ca は作られなくなる (入力の変化は自動検知して作り直す)。
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
#   ca/cacert.crt                 ★自己証明書 (受領物 もしくは 自動発行)。唯一のトラストアンカー
#   ca/cacert.key                 その秘密鍵。generate モード / 受領物に鍵がある場合のみ存在
#   ca/local-test-ca.crt|key      受領物に鍵が無い場合だけ生成するサーバ証明書発行用ローカル CA
#   ca/verify-bundle.crt          ★サーバ証明書の検証に使う CA バンドル
#                                   = cacert.crt (+ 鍵なし時のみ local-test-ca.crt)
#                                   mysqld の --ssl_ca / nginx の proxy_ssl_trusted_certificate /
#                                   tls-verifier の CA_BUNDLE がこれを参照する
#   secure-api/server.crt|key     secure-api のサーバ証明書
#   secure-api/fullchain.crt      サーバ証明書 + 発行元 CA (サーバが提示するチェーン)
#   secure-api/server.p12         WireMock (Jetty) 用 PKCS#12 キーストア
#   alb/ca-issued/*               ALB 用 (CA 発行) — ACM 発行相当
#   alb/selfsigned/*              ALB 用 (自己署名リーフ) — 自己証明書適用パターン
#   rds-proxy/server.crt|key      MySQL (RDS Proxy 相当) のサーバ証明書
#   rds-proxy/fullchain.crt       サーバ証明書 + 発行元 CA (mysqld が提示するチェーン)
#   trust/cacert.crt              ★front/back の JDK / JBoss トラストストアへ入れる本命 (受領物)
#   trust/alb-selfsigned.crt      ALB 自己署名リーフを使うとき用 (パターン B)
#   trust/local-test-ca.crt       鍵なし & PKI_TRUST_LOCAL_CA=1 のときだけ配置
#   .pki-ready                    生成完了マーカー (healthcheck が参照)
#   .pki-source                   入力のシグネチャ (モード / 受領物の SHA-256 など)。
#                                 受領した cacert.crt を差し替えると値が変わるため、
#                                 PKI_FORCE_REGENERATE を付けなくても自動で作り直す
#
# 注意: テスト環境専用のため秘密鍵はパスフレーズ無し・mode 0644 で配置する
#       (コンテナごとに実行ユーザが違うため。本番でこの構成にしないこと)。
# =============================================================================
set -eu

PKI_ROOT="${PKI_ROOT:-/pki}"
# 受領済み自己証明書の投入口 (compose が bind mount する。既定はホストの
# compose/pki/provided/。.env の PKI_PROVIDED_DIR で任意のホストパスへ変更可)
PROVIDED_DIR="${PKI_PROVIDED_DIR:-/provided}"
# auto     … provided/cacert.crt があれば provided、無ければ generate
# provided … 受領物必須 (無ければ起動失敗させる)
# generate … 従来どおり全部自動発行 (受領物があっても無視する)
PKI_MODE="${PKI_MODE:-auto}"
# 受領物に鍵が無いとき、サーバ証明書発行用のローカル CA をトラストストアへ入れるか
TRUST_LOCAL_CA="${PKI_TRUST_LOCAL_CA:-1}"

DAYS_CA="${PKI_DAYS_CA:-3650}"
DAYS_LEAF="${PKI_DAYS_LEAF:-825}"
KEY_BITS="${PKI_KEY_BITS:-2048}"
KEYSTORE_PASSWORD="${PKI_KEYSTORE_PASSWORD:-changeit}"
FORCE="${PKI_FORCE_REGENERATE:-0}"

# 証明書のサブジェクト (テスト用。generate モードと local-test-ca でのみ使う)
SUBJ_BASE="${PKI_SUBJ_BASE:-/C=JP/ST=Tokyo/L=Chiyoda/O=Local Test Org/OU=Local Test PKI}"
# 自動発行する自己証明書 (CA) の CN。front/back のトラストストア一覧でこの名前が見える
CA_CN="${PKI_CA_CN:-Local Test Self-Signed CA}"
# 受領物に鍵が無いときだけ作る「サーバ証明書発行専用」ローカル CA の CN。
# 受領 CA と取り違えないよう、名前で用途がはっきり分かるようにしている
LOCAL_CA_CN="${PKI_LOCAL_CA_CN:-Local Test Server-Issuing CA (no received key)}"

# SAN。compose のサービス名で名前解決するため DNS 名にサービス名を必ず含める
SECURE_API_SAN="${PKI_SECURE_API_SAN:-DNS:secure-api,DNS:secure-api.local,DNS:localhost,IP:127.0.0.1}"
ALB_SAN="${PKI_ALB_SAN:-DNS:alb,DNS:alb.local,DNS:alb.example.internal,DNS:localhost,IP:127.0.0.1}"
# DB 経路。front/back は DB_HOST=mysql で接続するため DNS:mysql が必須。
# 実 AWS ではここが RDS Proxy のエンドポイント FQDN
# (例: <proxy>.proxy-<id>.<region>.rds.amazonaws.com) になる。
RDS_PROXY_SAN="${PKI_RDS_PROXY_SAN:-DNS:mysql,DNS:mysql.local,DNS:localhost,IP:127.0.0.1}"

log() { echo "[pki-init] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

MARKER="${PKI_ROOT}/.pki-ready"
SIGFILE="${PKI_ROOT}/.pki-source"
CACERT="${PKI_ROOT}/ca/cacert.crt"
CAKEY="${PKI_ROOT}/ca/cacert.key"
LOCAL_CA_CRT="${PKI_ROOT}/ca/local-test-ca.crt"
LOCAL_CA_KEY="${PKI_ROOT}/ca/local-test-ca.key"
VERIFY_BUNDLE="${PKI_ROOT}/ca/verify-bundle.crt"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# =============================================================================
# 1. 受領物の検出と検証
# =============================================================================
# 受領ファイルの候補。実運用で連携されてくる名前は cacert.crt が基本だが、
# PEM 拡張子で渡されることもあるため .pem も拾う
find_provided_cert() {
  for _f in "${PROVIDED_DIR}/cacert.crt" "${PROVIDED_DIR}/cacert.pem"; do
    [ -f "${_f}" ] && { echo "${_f}"; return 0; }
  done
  return 1
}
find_provided_key() {
  for _f in "${PROVIDED_DIR}/cacert.key" "${PROVIDED_DIR}/cacert-key.pem"; do
    [ -f "${_f}" ] && { echo "${_f}"; return 0; }
  done
  return 1
}

# 受領証明書を PEM へ正規化して $2 へ書き出す。
# ・PEM / DER のどちらで渡されても受け取れるようにする (Windows 経由だと DER のことがある)
# ・"Bag Attributes" 等の余計なテキストが前後に付いていても落とす
# ・openssl x509 は先頭の 1 枚だけを読むため、チェーンで渡された場合は警告する
normalize_cert() {  # $1=入力 $2=出力(PEM)
  if openssl x509 -in "$1" -inform PEM -noout >/dev/null 2>&1; then
    openssl x509 -in "$1" -inform PEM -out "$2" >/dev/null 2>&1 || return 1
  elif openssl x509 -in "$1" -inform DER -noout >/dev/null 2>&1; then
    log "受領した証明書は DER 形式でした。PEM へ変換して取り込みます"
    openssl x509 -in "$1" -inform DER -out "$2" >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  return 0
}

fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'; }

# --- モードの決定 ------------------------------------------------------------
PROVIDED_CRT_SRC=""
PROVIDED_KEY_SRC=""
MODE=""

case "${PKI_MODE}" in
  generate)
    MODE="generate"
    log "PKI_MODE=generate のため、受領物があっても無視して自動発行します"
    ;;
  provided|auto)
    if PROVIDED_CRT_SRC="$(find_provided_cert)"; then
      MODE="provided"
    elif [ "${PKI_MODE}" = "provided" ]; then
      die "PKI_MODE=provided ですが ${PROVIDED_DIR}/cacert.crt が見つかりません。
       受領した自己証明書を compose/pki/provided/cacert.crt へ置いてください
       (別の場所に置く場合は .env の PKI_PROVIDED_DIR でホストパスを指定)"
    else
      MODE="generate"
      log "${PROVIDED_DIR}/cacert.crt が無いため、従来どおり自己署名 CA を発行します"
      log "受領済みの cacert.crt を使う場合は compose/pki/provided/cacert.crt へ配置してください"
    fi
    ;;
  *)
    die "PKI_MODE の値が不正です: ${PKI_MODE} (auto|provided|generate)"
    ;;
esac

# --- 受領物の検査 (モード判定後、再生成の要否を決める前に行う) ----------------
PROVIDED_HAS_KEY=0
PROVIDED_FP=""
if [ "${MODE}" = "provided" ]; then
  normalize_cert "${PROVIDED_CRT_SRC}" "${TMP}/cacert.crt" \
    || die "${PROVIDED_CRT_SRC} を X.509 証明書として読めません (PEM / DER のいずれでもない)"

  # チェーンで渡された場合の注意喚起 (先頭 1 枚しか使わない)
  _n_certs="$(grep -c 'BEGIN CERTIFICATE' "${PROVIDED_CRT_SRC}" 2>/dev/null || echo 0)"
  if [ "${_n_certs}" -gt 1 ]; then
    log "WARN: 受領ファイルに証明書が ${_n_certs} 枚含まれています。先頭の 1 枚だけをトラストアンカーとして使います"
  fi

  PROVIDED_FP="$(fingerprint "${TMP}/cacert.crt")"

  if PROVIDED_KEY_SRC="$(find_provided_key)"; then
    # 鍵と証明書が同じ公開鍵を持つか (取り違え検出)
    openssl pkey -in "${PROVIDED_KEY_SRC}" -pubout -out "${TMP}/key.pub" >/dev/null 2>&1 \
      || die "${PROVIDED_KEY_SRC} を秘密鍵として読めません (パスフレーズ付きの鍵は非対応)"
    openssl x509 -in "${TMP}/cacert.crt" -noout -pubkey > "${TMP}/crt.pub" 2>/dev/null
    if cmp -s "${TMP}/key.pub" "${TMP}/crt.pub"; then
      PROVIDED_HAS_KEY=1
    else
      die "${PROVIDED_KEY_SRC} は ${PROVIDED_CRT_SRC} の秘密鍵ではありません (公開鍵が一致しない)"
    fi
  fi
fi

# --- 入力シグネチャ (差し替え検知) -------------------------------------------
# 受領した cacert.crt を別のものに差し替えたのに .pki-ready のせいで
# 古い証明書が使われ続ける、という事故を防ぐ。
SOURCE_SIG="mode=${MODE} ca=${PROVIDED_FP:-generated} key=${PROVIDED_HAS_KEY} trustlocal=${TRUST_LOCAL_CA}"

NEED_REGEN=0
if [ "${FORCE}" = "1" ]; then
  NEED_REGEN=1
  log "PKI_FORCE_REGENERATE=1 のため PKI を再生成します"
elif [ ! -f "${MARKER}" ]; then
  NEED_REGEN=1
elif [ ! -f "${SIGFILE}" ] || [ "$(cat "${SIGFILE}" 2>/dev/null)" != "${SOURCE_SIG}" ]; then
  NEED_REGEN=1
  log "入力が変わりました (受領証明書の差し替え / モード変更) → PKI を作り直します"
  log "  以前: $(cat "${SIGFILE}" 2>/dev/null || echo '(記録なし)')"
  log "  今回: ${SOURCE_SIG}"
fi

# =============================================================================
# 2. 配備 (必要なときだけ)
# =============================================================================
if [ "${NEED_REGEN}" = "0" ]; then
  log "既存の PKI を再利用します (作り直すには PKI_FORCE_REGENERATE=1)"
  log "generated at: $(cat "${MARKER}")"
  log "source      : $(cat "${SIGFILE}" 2>/dev/null || echo '(記録なし)')"
else
  rm -f "${MARKER}" "${SIGFILE}"
  mkdir -p "${PKI_ROOT}/ca" \
           "${PKI_ROOT}/secure-api" \
           "${PKI_ROOT}/alb/ca-issued" \
           "${PKI_ROOT}/alb/selfsigned" \
           "${PKI_ROOT}/rds-proxy" \
           "${PKI_ROOT}/trust"

  # 前回の成果物が volume に残っていると、古い CA で発行された証明書や
  # 別モードの残骸 (例: generate → provided(鍵なし) へ切り替えたときの ca/cacert.key)
  # を拾ってしまう。作り直すときは確実に消す (down -v をしなくても切り替わるように)。
  rm -f "${CACERT}" "${CAKEY}" "${LOCAL_CA_CRT}" "${LOCAL_CA_KEY}" "${VERIFY_BUNDLE}"
  rm -f "${PKI_ROOT}/ca/root-ca.crt"         "${PKI_ROOT}/ca/root-ca.key" \
        "${PKI_ROOT}/ca/intermediate-ca.crt" "${PKI_ROOT}/ca/intermediate-ca.key" \
        "${PKI_ROOT}/ca/ca-chain.crt"        "${PKI_ROOT}/ca"/*.srl
  rm -f "${PKI_ROOT}/trust"/*.crt

  # -------------------------------------------------------------------------
  # 2-1) トラストアンカー cacert.crt を用意する
  #      provided … 受領物をそのままコピー (中身は一切書き換えない)
  #      generate … 自己署名 CA を新規発行
  # -------------------------------------------------------------------------
  if [ "${MODE}" = "provided" ]; then
    log "1/6 受領済みの自己証明書を配備します (発行はしません)"
    log "    受領ファイル: ${PROVIDED_CRT_SRC}"
    cp "${TMP}/cacert.crt" "${CACERT}"
    if [ "${PROVIDED_HAS_KEY}" = "1" ]; then
      cp "${PROVIDED_KEY_SRC}" "${CAKEY}"
      log "    秘密鍵も受領済み (${PROVIDED_KEY_SRC}) → 受領 CA でサーバ証明書を発行します"
    else
      log "    秘密鍵は受領していません → サーバ証明書は local-test-ca で発行します"
    fi
  else
    log "1/6 自己証明書 (自己署名 CA) を生成 CN=${CA_CN} (${DAYS_CA} 日)"
    # pathlen:0 = この CA は下位 CA を作れない (リーフのみ発行できる)
    openssl req -x509 -newkey "rsa:${KEY_BITS}" -sha256 -days "${DAYS_CA}" -nodes \
      -keyout "${CAKEY}" \
      -out    "${CACERT}" \
      -subj   "${SUBJ_BASE}/CN=${CA_CN}" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1
  fi

  # --- 受領物の性質を検査してログに残す (provided モードのみ) ----------------
  CACERT_IS_CA=0
  if openssl x509 -in "${CACERT}" -noout -text 2>/dev/null | grep -q "CA:TRUE"; then
    CACERT_IS_CA=1
  fi
  if [ "${MODE}" = "provided" ]; then
    log "    subject    : $(openssl x509 -in "${CACERT}" -noout -subject | sed 's/^subject=//')"
    log "    issuer     : $(openssl x509 -in "${CACERT}" -noout -issuer  | sed 's/^issuer=//')"
    log "    notBefore  : $(openssl x509 -in "${CACERT}" -noout -startdate | sed 's/^notBefore=//')"
    log "    notAfter   : $(openssl x509 -in "${CACERT}" -noout -enddate   | sed 's/^notAfter=//')"
    log "    SHA-256 FP : ${PROVIDED_FP}"
    if openssl verify -CAfile "${CACERT}" "${CACERT}" >/dev/null 2>&1; then
      log "    自己署名    : YES (自分自身で検証できる = 自己証明書)"
    else
      log "WARN: 受領した cacert.crt は自己署名ではありません (上位 CA が発行した証明書の可能性)"
      log "WARN: トラストアンカーとして使うこと自体は可能ですが、想定と違う場合は受領物を確認してください"
    fi
    if [ "${CACERT_IS_CA}" = "1" ]; then
      log "    basicConstraints: CA:TRUE (CA 証明書)"
    else
      log "WARN: 受領した cacert.crt は CA 証明書ではありません (basicConstraints CA:TRUE が無い)"
      log "WARN: 自己署名リーフ証明書と思われます。この 1 枚だけを信頼する形になります"
    fi
    if ! openssl x509 -in "${CACERT}" -noout -checkend 0 >/dev/null 2>&1; then
      log "WARN: 受領した cacert.crt は有効期限が切れています。JVM は検証に失敗します"
    fi
  fi

  # -------------------------------------------------------------------------
  # 2-2) サーバ証明書の発行元 (issuer) を決める
  #      受領 CA の鍵が無い / 受領物が CA でない場合はローカル CA を作る。
  #      名前を local-test-ca にしてあるのは、トラストストア一覧やチェーン表示で
  #      「受領 CA ではない別物」だと一目で分かるようにするため。
  # -------------------------------------------------------------------------
  USE_LOCAL_CA=0
  if [ "${MODE}" = "provided" ]; then
    if [ "${PROVIDED_HAS_KEY}" != "1" ] || [ "${CACERT_IS_CA}" != "1" ]; then
      USE_LOCAL_CA=1
    fi
  fi

  if [ "${USE_LOCAL_CA}" = "1" ]; then
    log "2/6 サーバ証明書発行用のローカル CA を生成 CN=${LOCAL_CA_CN}"
    log "    (受領 cacert.crt の秘密鍵が無いため。受領 CA では署名できません)"
    openssl req -x509 -newkey "rsa:${KEY_BITS}" -sha256 -days "${DAYS_CA}" -nodes \
      -keyout "${LOCAL_CA_KEY}" \
      -out    "${LOCAL_CA_CRT}" \
      -subj   "${SUBJ_BASE}/CN=${LOCAL_CA_CN}" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1
    ISSUER_CRT="${LOCAL_CA_CRT}"
    ISSUER_KEY="${LOCAL_CA_KEY}"
    ISSUER_LABEL="local-test-ca"
  else
    log "2/6 サーバ証明書の発行元 = cacert.crt (トラストアンカーと同一)"
    ISSUER_CRT="${CACERT}"
    ISSUER_KEY="${CAKEY}"
    ISSUER_LABEL="cacert"
  fi

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

  # 決定した issuer でサーバ証明書を発行する
  issue_from_ca() {  # $1=出力ディレクトリ  $2=CN  $3=SAN
    _dir="$1"; _cn="$2"; _san="$3"
    make_server_ext "${TMP}/server.ext" "${_san}"
    openssl req -new -newkey "rsa:${KEY_BITS}" -nodes \
      -keyout "${_dir}/server.key" -out "${TMP}/server.csr" \
      -subj "${SUBJ_BASE}/CN=${_cn}" >/dev/null 2>&1
    openssl x509 -req -in "${TMP}/server.csr" \
      -CA "${ISSUER_CRT}" -CAkey "${ISSUER_KEY}" \
      -CAcreateserial -days "${DAYS_LEAF}" -sha256 -extfile "${TMP}/server.ext" \
      -out "${_dir}/server.crt" >/dev/null 2>&1
    # サーバが提示するチェーン (リーフ + 発行元 CA)。
    # クライアントが CA を持っている前提なので添付は必須ではないが、
    # nginx / mysqld / Jetty で設定を共通化するため常に作る
    cat "${_dir}/server.crt" "${ISSUER_CRT}" > "${_dir}/fullchain.crt"
  }

  # -------------------------------------------------------------------------
  # 2-3) secure-api のサーバ証明書 — ★接続確認の本命の接続先
  # -------------------------------------------------------------------------
  log "3/6 secure-api のサーバ証明書を発行 (issuer=${ISSUER_LABEL}, SAN=${SECURE_API_SAN})"
  issue_from_ca "${PKI_ROOT}/secure-api" "secure-api" "${SECURE_API_SAN}"

  # WireMock (Jetty) は JKS/PKCS#12 キーストアを要求するため PKCS#12 に固める。
  # -certfile で発行元 CA を同梱し、サーバがチェーンを提示できるようにする。
  openssl pkcs12 -export \
    -inkey    "${PKI_ROOT}/secure-api/server.key" \
    -in       "${PKI_ROOT}/secure-api/server.crt" \
    -certfile "${ISSUER_CRT}" \
    -name     "secure-api" \
    -out      "${PKI_ROOT}/secure-api/server.p12" \
    -passout  "pass:${KEYSTORE_PASSWORD}" >/dev/null 2>&1

  # -------------------------------------------------------------------------
  # 2-4) ALB のサーバ証明書 (パターン A: CA 発行 = ACM 発行相当)
  # -------------------------------------------------------------------------
  log "4/6 ALB のサーバ証明書 (CA 発行) を発行 issuer=${ISSUER_LABEL} SAN=${ALB_SAN}"
  issue_from_ca "${PKI_ROOT}/alb/ca-issued" "alb.example.internal" "${ALB_SAN}"

  # -------------------------------------------------------------------------
  # 2-5) ALB のサーバ証明書 (パターン B: 自己署名リーフ = 自己証明書をそのまま適用)
  #      CA を介さないため、信頼させるにはこの証明書自体をトラストストアへ入れる。
  # -------------------------------------------------------------------------
  log "5/6 ALB のサーバ証明書 (自己署名リーフ) を発行 SAN=${ALB_SAN}"
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
  # 2-6) MySQL (RDS Proxy 相当) のサーバ証明書
  #    コミュニティ版 mysqld は既定で初回起動時に「自己署名の ca.pem + サーバ証明書」を
  #    自動生成する。それだと
  #      [Warning] [MY-010068] CA certificate ca.pem is self signed.
  #    が出るうえ、証明書の CN が MySQL_Server_<version>_Auto_Generated_Server_Certificate
  #    で SAN も無いため sslMode=VERIFY_CA / VERIFY_IDENTITY が成立しない。
  #    本番の RDS Proxy は Amazon RDS CA が発行した証明書を提示するので、
  #    ローカルでも CA 発行の証明書を用意して mysqld に使わせ、挙動をそろえる。
  # -------------------------------------------------------------------------
  log "6/6 MySQL (RDS Proxy 相当) のサーバ証明書を発行 (issuer=${ISSUER_LABEL}, SAN=${RDS_PROXY_SAN})"
  issue_from_ca "${PKI_ROOT}/rds-proxy" "mysql" "${RDS_PROXY_SAN}"

  # -------------------------------------------------------------------------
  # 2-7) 検証用 CA バンドルと、トラストストア投入用の証明書を配置
  #
  #  verify-bundle.crt … 「このスタックのサーバ証明書を検証できる CA の集合」。
  #      mysqld の --ssl_ca / nginx の proxy_ssl_trusted_certificate /
  #      tls-verifier の CA_BUNDLE がこれを参照する。
  #      受領 CA でリーフを発行できている場合は cacert.crt 1 枚と同じ内容になる。
  #
  #  trust/ … front/back の entrypoint が keytool で
  #      「JDK 同梱 cacerts のコピー」と「JBoss (Elytron) 用トラストストア」の
  #      両方へ取り込む。ファイル名 (拡張子除く) がそのまま keytool の alias になる。
  #      cacert.crt は常に★受領物そのもの★が入る (これがこの検証の本命)。
  # -------------------------------------------------------------------------
  cp "${CACERT}"                               "${PKI_ROOT}/trust/cacert.crt"
  cp "${PKI_ROOT}/alb/selfsigned/server.crt"   "${PKI_ROOT}/trust/alb-selfsigned.crt"

  if [ "${USE_LOCAL_CA}" = "1" ]; then
    cat "${CACERT}" "${LOCAL_CA_CRT}" > "${VERIFY_BUNDLE}"
    if [ "${TRUST_LOCAL_CA}" = "1" ]; then
      cp "${LOCAL_CA_CRT}" "${PKI_ROOT}/trust/local-test-ca.crt"
      log "トラストストア投入: cacert.crt (受領物) + alb-selfsigned.crt + local-test-ca.crt"
      log "  → 受領 cacert.crt の取り込み検証と、HTTPS 疎通の正常系の両方を確認できます"
    else
      log "トラストストア投入: cacert.crt (受領物) + alb-selfsigned.crt"
      log "  → PKI_TRUST_LOCAL_CA=0 のため local-test-ca は信頼しません。"
      log "    secure-api / ALB(ca-issued) への接続は PKIX で失敗します (それが期待値)"
    fi
  else
    cp "${CACERT}" "${VERIFY_BUNDLE}"
    log "トラストストア投入: cacert.crt + alb-selfsigned.crt"
  fi

  # 実行ユーザがコンテナごとに異なる (jboss=185 / wiremock=1000 / nginx=root /
  # mysql=999) ため、テスト用途に限り全ファイルを読み取り可能にする
  chmod 0755 "${PKI_ROOT}" "${PKI_ROOT}/ca" "${PKI_ROOT}/secure-api" \
             "${PKI_ROOT}/alb" "${PKI_ROOT}/alb/ca-issued" "${PKI_ROOT}/alb/selfsigned" \
             "${PKI_ROOT}/rds-proxy" "${PKI_ROOT}/trust"
  find "${PKI_ROOT}" -type f -exec chmod 0644 {} +

  date -u '+%Y-%m-%dT%H:%M:%SZ' > "${MARKER}"
  printf '%s' "${SOURCE_SIG}" > "${SIGFILE}"
  chmod 0644 "${MARKER}" "${SIGFILE}"
  log "PKI 配備完了"
fi

# =============================================================================
# 3. 配備結果のサマリ (docker logs pki-init で確認できる)
# =============================================================================
# 再利用パス (NEED_REGEN=0) を通った場合でも表示できるよう、ここで状態を読み直す
if [ -f "${LOCAL_CA_CRT}" ]; then RUNTIME_LOCAL_CA=1; else RUNTIME_LOCAL_CA=0; fi

log "================================================================"
if [ "${MODE}" = "provided" ]; then
  log "MODE: provided — 受領済みの自己証明書 (cacert.crt) を使用中"
  log "  受領元: ${PROVIDED_CRT_SRC}"
  log "  SHA-256 fingerprint: ${PROVIDED_FP}"
  if [ "${RUNTIME_LOCAL_CA}" = "1" ]; then
    if [ "${PROVIDED_HAS_KEY}" = "1" ]; then
      # 鍵はあるが受領物が CA 証明書でない (自己署名リーフ) ケース
      log "  受領物が CA 証明書ではない (basicConstraints CA:TRUE が無い) ため、"
      log "  サーバ証明書は local-test-ca が発行しています"
    else
      log "  受領物に秘密鍵が無いため、サーバ証明書は local-test-ca が発行しています"
    fi
    log "  ・受領 cacert.crt   → トラストアンカーとして front/back へ配布 (trust/cacert.crt)"
    log "  ・local-test-ca     → secure-api / alb(ca-issued) / rds-proxy の発行元"
    if [ "${PROVIDED_HAS_KEY}" != "1" ]; then
      log "  cacert.key を ${PROVIDED_DIR} へ置けば、受領 CA が全証明書を発行する構成に自動で切り替わります"
    fi
  else
    log "  受領 CA がすべてのサーバ証明書を発行しています (cacert.crt 1 枚が唯一のトラストアンカー)"
  fi
else
  log "MODE: generate — 自己署名 CA をこのコンテナで発行しました"
  log "  受領済みの cacert.crt を使う場合は compose/pki/provided/cacert.crt へ配置してください"
fi
log "----------------------------------------------------------------"
for c in "${CACERT}" \
         "${LOCAL_CA_CRT}" \
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

# =============================================================================
# 4. 自己検証 (ここで失敗するなら配備がおかしい)
# =============================================================================
# 検証は verify-bundle.crt (= cacert.crt + 必要なら local-test-ca.crt) で行う。
# mysqld / nginx / tls-verifier も同じファイルを見るため、ここで通れば
# 実行時に MY-015010 や proxy_ssl_verify の失敗は起きない。
VERIFY_FAILED=0
for leaf in secure-api/server.crt rds-proxy/server.crt alb/ca-issued/server.crt; do
  if openssl verify -CAfile "${VERIFY_BUNDLE}" "${PKI_ROOT}/${leaf}" >/dev/null 2>&1; then
    log "chain verify OK: ${leaf} ← ca/verify-bundle.crt"
  else
    log "ERROR: ${leaf} のチェーン検証に失敗しました"
    VERIFY_FAILED=1
  fi
done
[ "${VERIFY_FAILED}" = "0" ] || exit 1

# 受領 cacert.crt 単体で何が検証できるかを明示する。
# 鍵なしモードではここが「検証できない」になるのが正しい挙動 (暗号的に不可避)。
if openssl verify -CAfile "${CACERT}" "${PKI_ROOT}/secure-api/server.crt" >/dev/null 2>&1; then
  log "★ cacert.crt 単体で secure-api のサーバ証明書を検証できます"
  log "  → 「受領した自己証明書を信頼したから HTTPS が通る」ことをそのまま検証できます"
else
  log "★ cacert.crt 単体では secure-api のサーバ証明書を検証できません (想定どおり)"
  if [ "${PROVIDED_HAS_KEY}" = "1" ]; then
    log "  → 受領物が CA 証明書ではないため、これでサーバ証明書を発行できないため。"
  else
    log "  → 受領 cacert.crt の秘密鍵が無く、サーバ証明書を受領 CA で発行できないため。"
  fi
  log "    受領物で確認できるのは「cacert.crt が JDK / JBoss のトラストストアへ"
  log "    正しく取り込まれること」までです (tls-verifier の項目 7)。"
  log "    HTTPS 疎通そのものは local-test-ca 発行の証明書で確認します。"
fi
log "================================================================"

# =============================================================================
# 5. 終了方法
# =============================================================================
# 既定: 常駐する。compose の depends_on: service_healthy で待たせるには
#       コンテナが running のままである必要があるため。
# --oneshot / PKI_ONESHOT=1: 配備したら終了する。証明書を入れ替えるときに使う:
#   docker compose run --rm -e PKI_FORCE_REGENERATE=1 pki-init --oneshot
if [ "${1:-}" = "--oneshot" ] || [ "${PKI_ONESHOT:-0}" = "1" ]; then
  log "--oneshot 指定のため終了します"
  exit 0
fi

# 他コンテナが volume 経由で参照するだけなので、常駐して healthy を維持する
exec tail -f /dev/null
