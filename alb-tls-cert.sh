#!/usr/bin/env bash
# =============================================================================
# ALB (nginx) の HTTPS リスナーに適用するサーバ証明書を切り替える
# ---------------------------------------------------------------------------
#   ./alb-tls-cert.sh selfsigned  → 自己署名リーフ証明書を適用 (既定)
#   ./alb-tls-cert.sh ca-issued   → 中間 CA が発行した証明書を適用 (ACM 発行相当)
#   ./alb-tls-cert.sh status      → 現在適用中の証明書と、実際に提示される証明書を表示
#
# 仕組み: compose/alb/tls/variants/ の該当ファイルを
#         compose/alb/tls/10-server-cert.conf にコピーし、nginx を reload する。
#         証明書ファイル自体は pki-init が named volume (pki) に発行済みのため、
#         再ビルド・再生成は不要 (切り替えは即時)。
#
# どちらのパターンでも front/back は検証に成功する:
#   selfsigned → トラストストアに「その自己署名証明書そのもの」が入っている
#   ca-issued  → トラストストアに「中間 CA + ルート CA」が入っている
# 詳細は docs/TLS-SELF-SIGNED-ALB.md を参照。
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TLS_DIR="${DIR}/compose/alb/tls"
ACTIVE="${TLS_DIR}/10-server-cert.conf"

reload_nginx() {
  if docker compose exec -T alb nginx -t 2>/dev/null; then
    docker compose exec -T alb nginx -s reload
    echo "nginx を reload しました。"
  else
    echo "WARN: alb コンテナが未起動か nginx -t に失敗。設定ファイルは更新済みです。" >&2
    echo "      次回起動時、または 'docker compose restart alb' で反映されます。" >&2
  fi
}

case "${1:-}" in
  selfsigned)
    cp "${TLS_DIR}/variants/10-server-cert.selfsigned.conf" "${ACTIVE}"
    echo "ALB HTTPS リスナー証明書: 自己署名 (/pki/alb/selfsigned/)"
    reload_nginx
    ;;
  ca-issued)
    cp "${TLS_DIR}/variants/10-server-cert.ca-issued.conf" "${ACTIVE}"
    echo "ALB HTTPS リスナー証明書: 中間 CA 発行 (/pki/alb/ca-issued/)"
    reload_nginx
    ;;
  status)
    echo "現在の ${ACTIVE}:"
    echo "-----------------------------------------------------------------"
    grep -v '^\s*#' "${ACTIVE}" | grep -v '^\s*$' || true
    echo "-----------------------------------------------------------------"
    if grep -q "selfsigned" "${ACTIVE}"; then
      echo "→ 自己署名証明書パターンです。"
    else
      echo "→ 中間 CA 発行証明書パターンです。"
    fi
    echo ""
    echo "ALB が実際に提示している証明書 (localhost:9443):"
    if command -v openssl >/dev/null 2>&1; then
      echo | openssl s_client -connect localhost:9443 -servername alb 2>/dev/null \
        | openssl x509 -noout -subject -issuer -dates 2>/dev/null \
        || echo "  (ALB へ接続できません。docker compose up 済みか確認してください)"
    else
      echo "  (openssl が無いためスキップ。docker compose run --rm tls-verifier でも確認できます)"
    fi
    ;;
  *)
    echo "usage: $0 {selfsigned|ca-issued|status}" >&2
    exit 1
    ;;
esac
