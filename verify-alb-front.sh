#!/usr/bin/env bash
# =============================================================================
# frontend 向け ALB の偽装 (alb-front) 経由で、リダイレクトの Location が https で
# 返るか (JBoss EAP が X-Forwarded-Proto を反映しているか) を確認する
#   詳細は docs/ALB-FRONT-LOCATION.md を参照
# ---------------------------------------------------------------------------
#   ./verify-alb-front.sh                         既定の API (ALB_FRONT_CHECK_PATH)
#   ./verify-alb-front.sh /iwinmichl/xxx          確認する API を指定
#
#   1. ホストから https://localhost:<ポート><API> を curl し、Location と
#      JBoss EAP の診断ヘッダ (X-Redirect-Check-*) を表示する
#   2. 偽装 ALB のコンテナ内で report を実行し、
#        クライアント ──https──▶ alb-front ──http──▶ frontend
#      の区間ごとの確認結果と、Location が https で返るかの判定を表示する
#   3. 2 のレポートを ${ALB_FRONT_REPORT_DIR:-./.alb-front-reports}/ へ保存する
#
# 終了コードは report と同じ (0=OK / 1=NG / 2=実行不能 / 3=判定保留)。
# =============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${DIR}" || exit 2
# Git Bash (Windows) でコンテナ内パス (/opt/...) が書き換えられないようにする
export MSYS_NO_PATHCONV=1

API_PATH="${1:-}"
CLI=/opt/alb-front/alb-front.py
REPORT_DIR="${ALB_FRONT_REPORT_DIR:-${DIR}/.alb-front-reports}"
OUT_DIR="${DIR}/.pki-out"

if [[ -z "$(docker compose ps -q alb-front 2>/dev/null)" ]]; then
  echo "[ERROR] alb-front が起動していません: docker compose up -d alb-front" >&2
  exit 2
fi

port="$(docker compose exec -T alb-front printenv ALB_FRONT_HTTPS_PORT 2>/dev/null | tr -d '\r')"
port="${port:-8443}"
if [[ -z "${API_PATH}" ]]; then
  API_PATH="$(docker compose exec -T alb-front python3 "${CLI}" default-path 2>/dev/null | tr -d '\r')"
fi

echo "##############################################################"
echo "# 1) ホストから偽装 ALB へ https で要求 (Location と診断ヘッダ)"
echo "#    https://localhost:${port}${API_PATH}"
echo "##############################################################"
mkdir -p "${OUT_DIR}"
ca_file="${OUT_DIR}/alb-front-ca.crt"
docker compose exec -T alb-front cat /pki/ca/verify-bundle.crt > "${ca_file}" 2>/dev/null
curl_opts=(-s -D - -o /dev/null --max-time 30)
if [[ -s "${ca_file}" ]]; then
  # Git Bash では Windows の curl へ渡すため C:/... 形式へ直す (MSYS_NO_PATHCONV=1 のため)
  if command -v cygpath >/dev/null 2>&1; then
    curl_opts+=(--cacert "$(cygpath -m "${ca_file}")")
  else
    curl_opts+=(--cacert "${ca_file}")
  fi
else
  curl_opts+=(-k)
fi
# Windows の curl (Schannel) はテスト用 CA の失効確認ができず失敗するため確認を外す
if curl -V 2>/dev/null | grep -qi schannel; then
  curl_opts+=(--ssl-no-revoke)
fi
curl "${curl_opts[@]}" "https://localhost:${port}${API_PATH}" \
  | grep -iE '^HTTP/|^Location:|^X-Redirect-Check-' \
  || echo "(応答を取得できませんでした。docker compose logs alb-front を確認してください)"

echo ""
echo "##############################################################"
echo "# 2) 偽装 ALB のコンテナ内で Location ヘッダ確認レポート"
echo "##############################################################"
mkdir -p "${REPORT_DIR}"
report_file="${REPORT_DIR}/location-check_$(date '+%Y%m%d-%H%M%S').txt"
docker compose exec -T alb-front python3 "${CLI}" report "${API_PATH}" | tee "${report_file}"
status="${PIPESTATUS[0]}"

echo ""
echo "レポート : ${report_file}"
case "${status}" in
  0) echo "結果     : OK (Location は https で返り、X-Forwarded-Proto が JBoss EAP へ連携されている)" ;;
  1) echo "結果     : NG (Location が https で返らない。レポートの「対処」を参照)" ;;
  3) echo "結果     : 判定保留 (リダイレクトが返らなかった。API のパスとデプロイ状況を確認)" ;;
  *) echo "結果     : 実行不能 (exit=${status})" ;;
esac
exit "${status}"
