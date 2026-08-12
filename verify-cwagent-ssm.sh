#!/usr/bin/env bash
# =============================================================================
# CloudWatch Agent の「SSM Parameter Store (SecureString) 注入」パターンの動作確認
#   CW_CONFIG_CONTENT     … デフォルトロードされる主設定
#   CW_CONFIG_CONTENT_MID … 追加設定 (ECS タスク定義で追加の secrets を足す場合)
#
# 何を確認するか:
#   (1) 2 つのパラメータが環境変数として解決され /etc/cwagentconfig へ materialize されたか
#   (2) 実エージェントが **両方をマージ**して実効設定を作ったか (translator の出力で判定)
#   (3) マージ結果に沿って両系統のログが cloudwatch-logs-mock へ送信されるか
#
# 使い方:
#   docker compose up -d --build                       # 通常の構成を先に起動
#   docker compose --profile ssm-config up -d cwagent-ssm
#   ./verify-cwagent-ssm.sh
#
# 詳細は docs/CWAGENT-SSM-CONFIG.md を参照。
# =============================================================================
set -uo pipefail

SVC=cwagent-ssm
LOGS_MOCK="http://localhost:8480"
CFG_DIR=/etc/cwagentconfig
TRANSLATED_JSON=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
TRANSLATED_TOML=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.toml

# CW_CONFIG_CONTENT 由来 (compose/cwagent/ssm/cwagent-config.json) のロググループ
GROUPS_DEFAULT=("/local/myapp/ssm/app-front" "/local/myapp/ssm/app-back")
# CW_CONFIG_CONTENT_MID 由来 (compose/cwagent/ssm/cwagent-config-mid.json) のロググループ
GROUPS_MID=("/local/myapp/ssm/mid/front" "/local/myapp/ssm/mid/back")

WARN_COUNT=0
warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo "WARN: $*"; }

WORK="$(mktemp -d 2>/dev/null || echo "/tmp/cwagent-ssm-verify.$$")"
mkdir -p "${WORK}/cfg"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# docker cp のコピー先はホスト側のパス。Git Bash (MSYS) では
# コンテナ側パス (/etc/...) の勝手な変換を止めるため MSYS_NO_PATHCONV=1 を付けるが、
# その状態だとホスト側の POSIX パス (/tmp/...) も変換されず docker.exe が解決できない。
# そのため、コピー先だけは cygpath で Windows 形式へ直してから渡す。
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

echo "=== 1. cwagent-ssm の状態確認 ==="
if ! docker inspect "${SVC}" >/dev/null 2>&1; then
  echo "cwagent-ssm が起動していません。先に以下を実行してください:"
  echo "  docker compose up -d --build"
  echo "  docker compose --profile ssm-config up -d cwagent-ssm"
  exit 1
fi
docker compose --profile ssm-config ps "${SVC}"

echo ""
echo "=== 2. SSM 注入の偽装ログ ([cwagent-ssm]) ==="
# ラッパー (compose/cwagent/ssm-config-entrypoint.sh) が
# 「どのパラメータを、どこから取得して、どのファイルへ materialize したか」を出力する
SSM_REPORT=$(docker compose --profile ssm-config logs --no-color "${SVC}" 2>/dev/null \
  | grep -F "[cwagent-ssm]" || true)
if [[ -z "${SSM_REPORT}" ]]; then
  warn "SSM 注入の偽装ログが出ていません。"
  echo "      compose.yaml の cwagent-ssm.entrypoint と"
  echo "      ./compose/cwagent/ssm-config-entrypoint.sh のマウントを確認してください。"
else
  echo "${SSM_REPORT}" | sed 's/^/  /'
  SSM_RESULT=$(echo "${SSM_REPORT}" | grep -F "RESULT:" | tail -n 1 || true)
  case "${SSM_RESULT}" in
    *"RESULT: PASS"*) echo "  → SSM 注入の偽装: PASS" ;;
    *"RESULT: WARN"*) echo "  → SSM 注入の偽装: WARN (上記 WARN 行を確認)" ;;
    *"RESULT: FAIL"*) warn "SSM 注入の偽装が FAIL です (上記 FAIL 行を確認)" ;;
    *)                echo "  NOTE: RESULT 行を取得できませんでした" ;;
  esac
fi

echo ""
echo "=== 3. materialize 結果 (${CFG_DIR}) をコンテナから取り出して確認 ==="
# CloudWatch Agent のイメージには ls/cat が無いため、docker cp
# (コンテナ内バイナリ不要) でホストへ取り出して中身を見る。
# ここに 2 ファイル揃っていれば「CW_CONFIG_CONTENT と CW_CONFIG_CONTENT_MID の
# 両方が環境変数として解決され、エージェントの入力ディレクトリへ置かれた」証跡になる。
if MSYS_NO_PATHCONV=1 docker cp "${SVC}:${CFG_DIR}/." "$(host_path "${WORK}/cfg")" >/dev/null 2>&1; then
  MAT_COUNT=$(find "${WORK}/cfg" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  echo "materialize されたファイル: ${MAT_COUNT} 件"
  for f in "${WORK}/cfg"/*.json; do
    [[ -e "${f}" ]] || continue
    echo "-- $(basename "${f}") ($(wc -c < "${f}" | tr -d ' ') bytes) --"
    sed 's/^/    /' "${f}"
  done
  if [[ "${MAT_COUNT}" -lt 2 ]]; then
    warn "materialize されたファイルが 2 件未満です。"
    echo "      CWA_SSM_PARAMS と ./compose/cwagent/ssm/*.json の対応を確認してください。"
  fi
else
  warn "${CFG_DIR} を取り出せません (tmpfs マウント / entrypoint の失敗を確認してください)"
  MAT_COUNT=0
fi

echo ""
echo "=== 4. ★エージェントが両方をマージしたか (実効設定の確認) ==="
# ここがこの検証の本丸。materialize は「ラッパーが置いた」だけの証跡だが、
# translator が出力する実効設定に **両方のロググループが載っている** ことは
# 「実エージェントが CW_CONFIG_CONTENT と CW_CONFIG_CONTENT_MID をマージした」証跡になる。
MERGED_FILE=""
if MSYS_NO_PATHCONV=1 docker cp "${SVC}:${TRANSLATED_JSON}" "$(host_path "${WORK}/translated.json")" >/dev/null 2>&1; then
  MERGED_FILE="${WORK}/translated.json"
  echo "実効設定 (JSON): ${TRANSLATED_JSON}"
elif MSYS_NO_PATHCONV=1 docker cp "${SVC}:${TRANSLATED_TOML}" "$(host_path "${WORK}/translated.toml")" >/dev/null 2>&1; then
  MERGED_FILE="${WORK}/translated.toml"
  echo "実効設定 (TOML): ${TRANSLATED_TOML}"
fi

FOUND_DEFAULT=0
FOUND_MID=0
if [[ -z "${MERGED_FILE}" ]]; then
  warn "実効設定を取り出せません = translator がまだ動いていない / 失敗している可能性があります。"
  echo "      docker compose logs ${SVC} | grep -E 'Under path :|E!' でエラーを確認してください。"
else
  echo "-- 実効設定に含まれるロググループ --"
  for g in "${GROUPS_DEFAULT[@]}"; do
    if grep -qF "${g}" "${MERGED_FILE}"; then
      echo "  [CW_CONFIG_CONTENT]     ${g}: 含まれる"
      FOUND_DEFAULT=$((FOUND_DEFAULT + 1))
    else
      echo "  [CW_CONFIG_CONTENT]     ${g}: 含まれない"
    fi
  done
  for g in "${GROUPS_MID[@]}"; do
    if grep -qF "${g}" "${MERGED_FILE}"; then
      echo "  [CW_CONFIG_CONTENT_MID] ${g}: 含まれる"
      FOUND_MID=$((FOUND_MID + 1))
    else
      echo "  [CW_CONFIG_CONTENT_MID] ${g}: 含まれない"
    fi
  done

  # endpoint_override は主設定にしか書いていない。追加設定側のログもこの宛先へ
  # 飛ぶことが、マージが「上書き」ではなく「合成」であることの裏付けになる。
  if grep -qF "cloudwatch-logs-mock" "${MERGED_FILE}"; then
    echo "  endpoint_override (主設定のみに存在): 実効設定へ引き継がれている"
  else
    warn "endpoint_override が実効設定にありません (実 CloudWatch Logs へ送信しようとします)"
  fi

  echo ""
  if [[ "${FOUND_DEFAULT}" -gt 0 && "${FOUND_MID}" -gt 0 ]]; then
    echo "判定: CW_CONFIG_CONTENT + CW_CONFIG_CONTENT_MID の **マージ成立**"
    echo "      → ECS でも同じ 2 パラメータを secrets に足せば同じ実効設定になります。"
  elif [[ "${FOUND_DEFAULT}" -gt 0 ]]; then
    warn "主設定のみが反映され、CW_CONFIG_CONTENT_MID がマージされていません。"
    echo "      ${CFG_DIR} に 10-cwagent-config-mid.json が置かれているか (上記 3) と、"
    echo "      docker compose logs ${SVC} | grep -E 'Under path :|E!' を確認してください。"
    echo "      追加設定側の JSON が不正だと、その 1 ファイルだけ無視されることがあります。"
  else
    warn "実効設定にどちらのロググループも含まれていません = 設定を読み込めていません。"
  fi
fi

echo ""
echo "=== 5. 収集対象のログファイルへマーカーを書き込む ==="
# 主設定は /mnt/logs/app-*.log を、追加設定は /mnt/logs/{front,back}/logs/*.log を見る。
# 後者はアプリが常時書くとは限らないため、ここで明示的に作って検知させる。
MARKER="$(date -u +%Y-%m-%dT%H:%M:%SZ) verify-cwagent-ssm"
docker compose exec -T frontend sh -c \
  "echo '${MARKER} [app-front] default-config' >> /mnt/logs/app-front.log" >/dev/null 2>&1 \
  && echo "frontend → /mnt/logs/app-front.log: OK" \
  || warn "frontend から /mnt/logs/app-front.log へ書き込めません"
docker compose exec -T backend sh -c \
  "echo '${MARKER} [app-back] default-config' >> /mnt/logs/app-back.log" >/dev/null 2>&1 \
  && echo "backend → /mnt/logs/app-back.log: OK" \
  || warn "backend から /mnt/logs/app-back.log へ書き込めません"
docker compose exec -T frontend sh -c \
  "mkdir -p /mnt/logs/front/logs && echo '${MARKER} [app-front] mid-config' >> /mnt/logs/front/logs/server.log" >/dev/null 2>&1 \
  && echo "frontend → /mnt/logs/front/logs/server.log: OK" \
  || warn "frontend から /mnt/logs/front/logs/ へ書き込めません"
docker compose exec -T backend sh -c \
  "mkdir -p /mnt/logs/back/logs && echo '${MARKER} [app-back] mid-config' >> /mnt/logs/back/logs/server.log" >/dev/null 2>&1 \
  && echo "backend → /mnt/logs/back/logs/server.log: OK" \
  || warn "backend から /mnt/logs/back/logs/ へ書き込めません"

echo ""
echo "=== 6. cloudwatch-logs-mock への送信を確認 ==="
echo "(force_flush_interval=5s + ファイル検知の猶予を待機中...)"
sleep 20

# WireMock の request journal を「本文にロググループ名を含むか」で数える。
# PutLogEvents の本文は gzip されることがあるため、平文 JSON で送られる
# CreateLogGroup / CreateLogStream を判定材料にする
# (ストリームが作られた = そのロググループの収集定義が実効設定に載っていた)。
journal_count_body() {
  curl -s -X POST "${LOGS_MOCK}/__admin/requests/count" \
    -H "Content-Type: application/json" \
    -d "{\"method\":\"POST\",\"url\":\"/\",\"bodyPatterns\":[{\"contains\":\"$1\"}]}" \
    | sed -n 's/.*"count"[^0-9]*\([0-9][0-9]*\).*/\1/p'
}
journal_count_target() {
  curl -s -X POST "${LOGS_MOCK}/__admin/requests/count" \
    -H "Content-Type: application/json" \
    -d "{\"method\":\"POST\",\"url\":\"/\",\"headers\":{\"X-Amz-Target\":{\"equalTo\":\"$1\"}}}" \
    | sed -n 's/.*"count"[^0-9]*\([0-9][0-9]*\).*/\1/p'
}

echo "-- 6-1) API アクション別の受信件数 (cwagent / cwagent-ssm の合算) --"
for action in CreateLogGroup CreateLogStream PutLogEvents; do
  cnt=$(journal_count_target "Logs_20140328.${action}" || true)
  printf '  %-18s : %s 件\n' "${action}" "${cnt:-0}"
done

echo "-- 6-2) SSM 注入経路のロググループ別 (本文一致) --"
SENT_DEFAULT=0
SENT_MID=0
for g in "${GROUPS_DEFAULT[@]}"; do
  cnt=$(journal_count_body "${g}" || true)
  cnt="${cnt:-0}"
  printf '  [CW_CONFIG_CONTENT]     %-30s : %s 件\n' "${g}" "${cnt}"
  SENT_DEFAULT=$((SENT_DEFAULT + cnt))
done
for g in "${GROUPS_MID[@]}"; do
  cnt=$(journal_count_body "${g}" || true)
  cnt="${cnt:-0}"
  printf '  [CW_CONFIG_CONTENT_MID] %-30s : %s 件\n' "${g}" "${cnt}"
  SENT_MID=$((SENT_MID + cnt))
done

if [[ "${SENT_DEFAULT}" -gt 0 && "${SENT_MID}" -gt 0 ]]; then
  echo "  → 両系統の送信を確認: OK"
elif [[ "${SENT_DEFAULT}" -gt 0 ]]; then
  warn "主設定の送信のみ確認できました (CW_CONFIG_CONTENT_MID 側が 0 件)。"
  echo "      上記 4 のマージ判定と、/mnt/logs/{front,back}/logs/*.log の存在を確認してください。"
elif [[ "${MAT_COUNT}" -gt 0 ]]; then
  warn "SSM 注入経路の送信が確認できません。"
  echo "      上記 4 のマージ判定 → 下記 7 のエージェントログ、の順に切り分けてください。"
fi

echo ""
echo "=== 7. cwagent-ssm の自己診断 / エラー行 ==="
CWA_REPORT=$(docker compose --profile ssm-config logs --no-color "${SVC}" 2>/dev/null \
  | grep -F "[cwagent-verify]" || true)
if [[ -n "${CWA_REPORT}" ]]; then
  echo "${CWA_REPORT}" | grep -F "RESULT:" | tail -n 1 | sed 's/^/  /'
  FAILS=$(echo "${CWA_REPORT}" | grep -F "] FAIL " || true)
  if [[ -n "${FAILS}" ]]; then
    echo "-- 検出された FAIL (重複除去) --"
    echo "${FAILS}" | sed 's/.*\[cwagent-verify\]\[[^]]*\] *//' | sort -u | sed 's/^/  /'
  fi
else
  echo "  (自己診断レポートなし)"
fi

ERRORS=$(docker compose --profile ssm-config logs --no-color "${SVC}" 2>/dev/null \
  | grep -Ei "Under path :|no such file|permission denied|cannot open|connection refused|NoCredentialProviders|InvalidSignature|AccessDenied|panic|E! " \
  | tail -n 20 || true)
echo "-- エージェントのエラー行 (末尾 20 行) --"
if [[ -n "${ERRORS}" ]]; then
  echo "${ERRORS}" | sed 's/^/  /'
else
  echo "  (該当するエラー行なし)"
fi

echo ""
echo "=============================================================="
if [[ "${WARN_COUNT}" -eq 0 ]]; then
  echo "完了: WARN なし。"
else
  echo "完了: WARN ${WARN_COUNT} 件。上記の WARN 行を確認してください。"
fi
cat <<'EOS'

対応表 (ローカル ⇄ ECS):
  compose/cwagent/ssm/cwagent-config.json      → SSM /<APP>/<ENV>/cwagent-config      → CW_CONFIG_CONTENT
  compose/cwagent/ssm/cwagent-config-mid.json  → SSM /<APP>/<ENV>/cwagent-config-mid  → CW_CONFIG_CONTENT_MID

Parameter Store への登録と登録内容の確認 (Terraform):
  cd terraform && terraform init && terraform apply
  terraform output parameter_summary
  terraform output -raw verify_commands

詳細: docs/CWAGENT-SSM-CONFIG.md
EOS
