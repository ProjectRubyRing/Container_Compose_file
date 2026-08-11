#!/usr/bin/env bash
# =============================================================================
# pki-init が配備した自己証明書 (cacert.crt) の取り出しと配置
#   詳細は docs/TLS-SELF-SIGNED-ALB.md 第 3 章 を参照
# ---------------------------------------------------------------------------
#   ./pki-export.sh                      取り出して compose/pki/export/ へ置く (+内容表示)
#   ./pki-export.sh --to-provided        さらに compose/pki/provided/ へ配置する
#                                        (= この CA を「受領物」として固定する)
#   ./pki-export.sh --to <dir>           さらに任意のディレクトリへ配置する
#                                        (ベースイメージのビルドコンテキスト上の
#                                         「所定のディレクトリ」へ置く用途)
#   ./pki-export.sh --no-key             秘密鍵 (cacert.key) は取り出さない
#   ./pki-export.sh --show               取り出し済みファイルの情報表示のみ
#
# 【なぜこのスクリプトが要るのか】
#   pki-init は起動のたびに ${PKI_EXPORT_DIR} (既定 compose/pki/export/) へ
#   自動で書き出すので、通常はこのスクリプトを実行しなくてもファイルは揃っている。
#   このスクリプトの役割は次の 2 つ。
#     (1) export の bind mount を付けずに起動している / 出力が消えた場合に、
#         起動中の pki-init コンテナから確実に取り出す (docker compose exec)
#     (2) 取り出したものを provided/ やビルドコンテキストへ「配置」する
#
# 【出力した cacert.crt の使い道】
#   A) イメージのビルドへ build secret として渡す (ベースイメージと同じ方式)
#        docker compose -f compose.yaml -f compose.build-secret.yaml build app-front app-back
#        docker build --secret id=cacert,src=compose/pki/export/cacert.crt ...
#   B) compose/pki/provided/ へ置いて、その CA を受領物として固定する
#        ./pki-export.sh --to-provided
# =============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
EXPORT_DIR="${DIR}/compose/pki/export"
PROVIDED_DIR="${DIR}/compose/pki/provided"

WITH_KEY=1
TO_PROVIDED=0
TO_DIR=""
SHOW_ONLY=0

log()  { echo "[pki-export] $*"; }
warn() { echo "[pki-export] WARN: $*" >&2; }
die()  { echo "[pki-export] ERROR: $*" >&2; exit 1; }

usage() {
  # ファイル冒頭のコメントブロック (2 行目〜 set -uo pipefail の直前) をそのまま出す
  sed -n "2,$(($(grep -n '^set -uo pipefail' "$0" | cut -d: -f1) - 1))p" "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to-provided) TO_PROVIDED=1; shift ;;
    --to)          TO_DIR="${2:-}"; [[ -n "${TO_DIR}" ]] || die "--to にはディレクトリを指定してください"; shift 2 ;;
    --no-key)      WITH_KEY=0; shift ;;
    --with-key)    WITH_KEY=1; shift ;;
    --show)        SHOW_ONLY=1; shift ;;
    -h|--help)     usage 0 ;;
    *)             echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# 1. pki-init から取り出す (compose/pki/export/ へ)
# -----------------------------------------------------------------------------
# named volume は docker build から見えないため、ホスト側にファイルとして置く。
# pki-init が自動で書き出したものがあっても、ここで上書きして最新にそろえる。
pull_from_pki_init() {
  mkdir -p "${EXPORT_DIR}/trust"

  if ! docker compose ps --status running --services 2>/dev/null | grep -qx 'pki-init'; then
    warn "pki-init が起動していません (docker compose up -d pki-init)"
    if [[ -f "${EXPORT_DIR}/cacert.crt" ]]; then
      warn "既に出力済みの ${EXPORT_DIR#"${DIR}/"}/cacert.crt をそのまま使います"
      return 0
    fi
    die "取り出せる cacert.crt がありません"
  fi

  # 前回の出力が残っていると、モード切り替え時に古い鍵を掴む (provided モードの
  # 判定が変わって pki-init が起動失敗する)。取り出す前に必ず消す。
  rm -f "${EXPORT_DIR}/cacert.crt" "${EXPORT_DIR}/cacert.key" \
        "${EXPORT_DIR}/verify-bundle.crt" "${EXPORT_DIR}/trust"/*.crt

  if ! docker compose exec -T pki-init cat /pki/ca/cacert.crt > "${EXPORT_DIR}/cacert.crt" 2>/dev/null; then
    rm -f "${EXPORT_DIR}/cacert.crt"
    die "pki-init から /pki/ca/cacert.crt を取り出せません (docker compose logs pki-init を確認)"
  fi
  docker compose exec -T pki-init cat /pki/ca/verify-bundle.crt > "${EXPORT_DIR}/verify-bundle.crt" 2>/dev/null

  # front/back のトラストストアへ入る証明書一式 (alias = ファイル名)
  local f
  while read -r f; do
    [[ -n "${f}" ]] || continue
    docker compose exec -T pki-init cat "/pki/trust/${f}" > "${EXPORT_DIR}/trust/${f}" 2>/dev/null \
      || rm -f "${EXPORT_DIR}/trust/${f}"
  done < <(docker compose exec -T pki-init sh -c 'cd /pki/trust 2>/dev/null && ls *.crt 2>/dev/null' | tr -d '\r')

  # 秘密鍵は「あれば」取り出す (受領物が鍵なしの場合は存在しない)
  if (( WITH_KEY )); then
    if docker compose exec -T pki-init test -f /pki/ca/cacert.key 2>/dev/null; then
      docker compose exec -T pki-init cat /pki/ca/cacert.key > "${EXPORT_DIR}/cacert.key" 2>/dev/null
    fi
  fi

  log "取り出しました: ${EXPORT_DIR#"${DIR}/"}/"
}

# -----------------------------------------------------------------------------
# 2. 取り出したものの情報表示
# -----------------------------------------------------------------------------
show() {
  local crt="${EXPORT_DIR}/cacert.crt"
  [[ -f "${crt}" ]] || die "${crt#"${DIR}/"} がありません。先に ./pki-export.sh を実行してください"

  echo ""
  echo "=============================================================="
  echo " 出力先: ${EXPORT_DIR#"${DIR}/"}/"
  echo "=============================================================="
  if command -v openssl >/dev/null 2>&1; then
    echo "  subject    : $(openssl x509 -in "${crt}" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    echo "  issuer     : $(openssl x509 -in "${crt}" -noout -issuer  2>/dev/null | sed 's/^issuer=//')"
    echo "  notAfter   : $(openssl x509 -in "${crt}" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    echo "  SHA-256 FP : $(openssl x509 -in "${crt}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
    if openssl x509 -in "${crt}" -noout -text 2>/dev/null | grep -q "CA:TRUE"; then
      echo "  種別       : CA 証明書 (この CA が発行した証明書をすべて信頼することになる)"
    else
      echo "  種別       : 自己署名リーフ (この 1 枚だけを信頼する形)"
    fi
  else
    echo "  (openssl が無いため証明書の内容表示をスキップ)"
  fi
  echo "  ファイル   :"
  ( cd "${EXPORT_DIR}" && find . -type f | sort | sed 's/^\./               /' )
  if [[ -f "${EXPORT_DIR}/cacert.key" ]]; then
    echo ""
    echo "  ★cacert.key (CA の秘密鍵) を含みます。テスト環境専用。共有・コミットしないこと"
  fi
}

# -----------------------------------------------------------------------------
# 3. 配置 (provided/ や ビルドコンテキストの所定ディレクトリへ)
# -----------------------------------------------------------------------------
place_into() {  # $1=配置先ディレクトリ  $2=ラベル
  local dst="$1" label="$2"
  mkdir -p "${dst}" || die "${dst} を作成できません"

  cp -f "${EXPORT_DIR}/cacert.crt" "${dst}/cacert.crt" || die "${dst}/cacert.crt へコピーできません"
  log "配置しました (${label}): ${dst}/cacert.crt"

  if [[ -f "${EXPORT_DIR}/cacert.key" ]]; then
    cp -f "${EXPORT_DIR}/cacert.key" "${dst}/cacert.key"
    log "配置しました (${label}): ${dst}/cacert.key (CA 秘密鍵)"
  else
    # 鍵が無い状態で provided/ へ置くと、サーバ証明書は local-test-ca が発行する
    # (パターン B)。鍵を消し忘れると証明書と鍵が食い違って pki-init が起動失敗するため、
    # 古い鍵が残っていれば必ず消す。
    if [[ -f "${dst}/cacert.key" ]]; then
      rm -f "${dst}/cacert.key"
      log "配置先に残っていた古い cacert.key を削除しました (${dst})"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 実行
# -----------------------------------------------------------------------------
if (( SHOW_ONLY )); then
  show
  exit 0
fi

pull_from_pki_init
show

if (( TO_PROVIDED )); then
  echo ""
  place_into "${PROVIDED_DIR}" "provided"
  cat <<EOS

  → 次回以降 pki-init は provided モードになり、この CA を使い続けます。
    反映するには:
      docker compose restart pki-init
      docker compose restart secure-api alb mysql app-front app-back
      docker compose logs pki-init | grep -E 'MODE:|SHA-256'
EOS
fi

if [[ -n "${TO_DIR}" ]]; then
  echo ""
  place_into "${TO_DIR}" "build-context"
  cat <<EOS

  → ベースイメージのビルドでは、このファイルを build secret として渡します。
      docker build --secret id=cacert,src=${TO_DIR}/cacert.crt ...
    Dockerfile 側:
      RUN --mount=type=secret,id=cacert,target=/run/secrets/cacert.crt \\
          keytool -importcert -noprompt -trustcacerts -alias cacert \\
                  -file /run/secrets/cacert.crt \\
                  -keystore "\${JAVA_HOME}/lib/security/cacerts" -storepass changeit
EOS
fi

cat <<EOS

--------------------------------------------------------------
次にやること:
  ビルドへ渡す   : docker compose -f compose.yaml -f compose.build-secret.yaml build app-front app-back
                   docker compose -f compose.yaml -f compose.build-secret.yaml up -d
  取り込み確認   : docker compose logs app-front | grep 'truststore\[build\]'
                   curl -s http://localhost:8080/tls-probe/truststore | jq -r '.stores[].cacertSha256'
  受領物に固定   : ./pki-export.sh --to-provided
  一括検証       : ./verify-tls.sh
--------------------------------------------------------------
EOS
