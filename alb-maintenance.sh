#!/usr/bin/env bash
# =============================================================================
# ALB (nginx) の全面メンテナンスモードを ON/OFF 切り替えする
# ---------------------------------------------------------------------------
#   ./alb-maintenance.sh on    → 全リクエストをメンテナンス Lambda (503+画面) へ
#   ./alb-maintenance.sh off   → 通常モード (app-back へ) に戻す
#   ./alb-maintenance.sh status→ 現在の 10-routes.conf の内容を表示
#
# 仕組み: compose/alb/rules/variants/ の該当ファイルを
#         compose/alb/rules/10-routes.conf にコピーし、nginx を reload する。
#         リスナールールはボリュームマウントされているため再ビルド不要。
#
# 注意: /maintenance* へのルール (00-maintenance-path.conf) は本切り替えとは独立に
#       常時有効。ON/OFF に関わらず http://localhost:9080/maintenance で画面確認可。
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
RULES="${DIR}/compose/alb/rules"
ACTIVE="${RULES}/10-routes.conf"

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
  on)
    cp "${RULES}/variants/10-routes.maintenance.conf" "${ACTIVE}"
    echo "メンテナンスモード: ON (全経路 → メンテナンス Lambda / 503)"
    reload_nginx
    ;;
  off)
    cp "${RULES}/variants/10-routes.normal.conf" "${ACTIVE}"
    echo "メンテナンスモード: OFF (通常 → app-back)"
    reload_nginx
    ;;
  status)
    echo "現在の ${ACTIVE}:"
    echo "-----------------------------------------------------------------"
    grep -v '^\s*#' "${ACTIVE}" | grep -v '^\s*$' || true
    echo "-----------------------------------------------------------------"
    if grep -q "maint_adapter" "${ACTIVE}"; then
      echo "→ 全面メンテナンスモード (ON) です。"
    else
      echo "→ 通常モード (OFF) です。"
    fi
    ;;
  *)
    echo "usage: $0 {on|off|status}" >&2
    exit 1
    ;;
esac
