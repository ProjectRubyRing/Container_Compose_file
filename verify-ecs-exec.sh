#!/usr/bin/env bash
# =============================================================================
# ECS Exec 偽装 (ecs-exec サービス) の動作確認
#
# 何を確認するか:
#   (1) 実物と同じコマンド体系で frontend (app-front) / backend (app-back) の
#       中でコマンドを実行できるか
#   (2) ECS の API 応答の体裁 (list-tasks / describe-tasks / managedAgents) が
#       出るか
#   (3) ファイルを送り込み / 取り出しできるか (base64 経由・sha256 一致)
#   (4) 失敗パターンが実物と同じ例外名で出るか
#       (クラスター名誤り / コンテナ名誤り / exec 無効化 / エージェント停止)
#   (5) セッションログが実物と同じ階層で残るか
#
# 使い方:
#   docker compose up -d --build
#   ./verify-ecs-exec.sh
#
# 詳細は docs/ECS-EXEC.md を参照。
# =============================================================================
set -uo pipefail

SVC=ecs-exec
CLUSTER=myapp-local-cluster
SERVICE=myapp-local-service
FRONT_CONTAINER=app-front
BACK_CONTAINER=app-back
FILES_DIR="compose/ecs-exec/files"
SESSIONS_DIR="compose/ecs-exec/sessions"

# Git Bash (MSYS) がコンテナ内パス (/work/... など) を Windows パスへ
# 勝手に変換するのを止める。ホスト側の操作にはシェル組み込みしか使わない
export MSYS_NO_PATHCONV=1

FAIL_COUNT=0
OK_COUNT=0
ok()   { OK_COUNT=$((OK_COUNT + 1));     echo "  OK   $*"; }
ng()   { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  NG   $*"; }
info() { echo "       $*"; }

# ecs-exec コンテナの中で実行する (端末は割り当てない)
ee() { docker compose exec -T "${SVC}" "$@" 2>&1; }

cleanup() {
  # 途中で失敗しても enableExecuteCommand は必ず戻す
  docker compose exec -T "${SVC}" aws ecs update-service --cluster "${CLUSTER}" \
    --service "${SERVICE}" --enable-execute-command >/dev/null 2>&1
  rm -f "${FILES_DIR}/verify-src.bin" "${FILES_DIR}/verify-back.bin"
}
trap cleanup EXIT

echo "=== 1. ecs-exec サービスの状態 ==="
if ! docker inspect "${SVC}" >/dev/null 2>&1; then
  echo "ecs-exec が起動していません。先に以下を実行してください:"
  echo "  docker compose up -d --build"
  exit 1
fi
docker compose ps "${SVC}"
echo ""

echo "=== 2. 前提の点検 (ecs-exec doctor) ==="
DOCTOR=$(ee ecs-exec doctor)
echo "${DOCTOR}" | sed 's/^/  /'
if echo "${DOCTOR}" | grep -q "^NG "; then
  # adot-collector / cwagent を起動していない場合もここに出る (致命的ではない)
  info "NG の行がある。app-front / app-back が RUNNING なら以降の確認は続行できる"
fi
echo ""

echo "=== 3. タスクを引く (list-tasks → describe-tasks) ==="
TASK_ARN=$(ee aws ecs list-tasks --cluster "${CLUSTER}" --query 'taskArns[0]' --output text | tr -d '\r')
if [[ "${TASK_ARN}" == arn:aws:ecs:* ]]; then
  ok "list-tasks がタスク ARN を返した"
  info "${TASK_ARN}"
else
  ng "list-tasks がタスク ARN を返さない: ${TASK_ARN}"
  echo ""
  echo "以降の確認は続けられません。"
  exit 1
fi
TASK_ID="${TASK_ARN##*/}"

ENABLED=$(ee aws ecs describe-tasks --cluster "${CLUSTER}" --tasks "${TASK_ID}" \
  --query 'tasks[0].enableExecuteCommand' --output text | tr -d '\r')
[[ "${ENABLED}" == "True" ]] \
  && ok "describe-tasks: enableExecuteCommand=True" \
  || ng "describe-tasks: enableExecuteCommand=${ENABLED} (True を期待)"

AGENT=$(ee aws ecs describe-tasks --cluster "${CLUSTER}" --tasks "${TASK_ID}" \
  --query 'tasks[0].containers[0].managedAgents[0].lastStatus' --output text | tr -d '\r')
[[ "${AGENT}" == "RUNNING" ]] \
  && ok "describe-tasks: ExecuteCommandAgent=RUNNING (app-front)" \
  || ng "describe-tasks: ExecuteCommandAgent=${AGENT} (RUNNING を期待)"

NAMES=$(ee aws ecs describe-tasks --cluster "${CLUSTER}" --tasks "${TASK_ID}" \
  --query 'tasks[0].containers[*].name' --output text | tr -d '\r' | tr '\n' ' ')
info "コンテナ: ${NAMES}"
echo ""

echo "=== 4. execute-command でコマンドを実行 (実物と同じ引数) ==="
for TARGET in "${FRONT_CONTAINER}" "${BACK_CONTAINER}"; do
  OUT=$(ee aws ecs execute-command --cluster "${CLUSTER}" --task "${TASK_ID}" \
    --container "${TARGET}" --interactive \
    --command "sh -c 'echo ECS_EXEC_OK_${TARGET}; id -u'")
  RC=$?
  if [[ ${RC} -eq 0 ]] && echo "${OUT}" | grep -q "ECS_EXEC_OK_${TARGET}"; then
    ok "${TARGET} でコマンドを実行できた (uid=$(echo "${OUT}" | tr -d '\r' | grep -E '^[0-9]+$' | tail -n 1))"
  else
    ng "${TARGET} でコマンドを実行できない (rc=${RC})"
    echo "${OUT}" | sed 's/^/       /'
  fi
  echo "${OUT}" | grep -q "Starting session with SessionId: ecs-execute-command-" \
    && ok "${TARGET}: セッション開始の出力が実物と同じ体裁" \
    || ng "${TARGET}: セッション開始の出力が出ていない"
done
echo ""

echo "=== 5. ファイルを送り込む (put: base64 をコマンド行に載せる方式) ==="
mkdir -p "${FILES_DIR}"
# 64KiB の擬似バイナリ (チャンク分割が起きる大きさ)
head -c 65536 /dev/urandom > "${FILES_DIR}/verify-src.bin" 2>/dev/null \
  || dd if=/dev/urandom of="${FILES_DIR}/verify-src.bin" bs=1024 count=64 >/dev/null 2>&1
SRC_SHA=$(sha256sum "${FILES_DIR}/verify-src.bin" | cut -d' ' -f1)
info "送信元 sha256: ${SRC_SHA}"

PUT_OUT=$(ee ecs-exec put /work/verify-src.bin "${FRONT_CONTAINER}:/tmp/verify-ecs-exec.bin")
PUT_RC=$?
echo "${PUT_OUT}" | grep -E "chunk |sha256" | sed 's/^/       /'
if [[ ${PUT_RC} -eq 0 ]] && echo "${PUT_OUT}" | grep -q "OK: sha256 一致"; then
  ok "put: 送り込み後の sha256 がコンテナ内でも一致"
else
  ng "put に失敗 (rc=${PUT_RC})"
  echo "${PUT_OUT}" | sed 's/^/       /'
fi

# 送り込んだ結果を execute-command 側からも確認する (put の自己申告に頼らない)
REMOTE_SHA=$(ee aws ecs execute-command --cluster "${CLUSTER}" --task "${TASK_ID}" \
  --container "${FRONT_CONTAINER}" --interactive \
  --command "sh -c 'sha256sum /tmp/verify-ecs-exec.bin | cut -d\" \" -f1'" \
  | tr -d '\r' | grep -E '^[0-9a-f]{64}$' | tail -n 1)
[[ "${REMOTE_SHA}" == "${SRC_SHA}" ]] \
  && ok "execute-command から見たコンテナ内の sha256 も一致" \
  || ng "コンテナ内の sha256 が違う (remote=${REMOTE_SHA:-取得できず})"
echo ""

echo "=== 6. ファイルを取り出す (get) ==="
GET_OUT=$(ee ecs-exec get "${FRONT_CONTAINER}:/tmp/verify-ecs-exec.bin" /work/verify-back.bin)
GET_RC=$?
echo "${GET_OUT}" | grep -E "sha256|書き出し" | sed 's/^/       /'
if [[ ${GET_RC} -eq 0 && -f "${FILES_DIR}/verify-back.bin" ]]; then
  BACK_SHA=$(sha256sum "${FILES_DIR}/verify-back.bin" | cut -d' ' -f1)
  [[ "${BACK_SHA}" == "${SRC_SHA}" ]] \
    && ok "get: 往復してもホスト側のファイルと同一 (${BACK_SHA:0:16}…)" \
    || ng "get: 往復で中身が変わった (${BACK_SHA} != ${SRC_SHA})"
else
  ng "get に失敗 (rc=${GET_RC})"
  echo "${GET_OUT}" | sed 's/^/       /'
fi
# 後片付け (コンテナ内)
ee aws ecs execute-command --cluster "${CLUSTER}" --task "${TASK_ID}" \
  --container "${FRONT_CONTAINER}" --interactive \
  --command "sh -c 'rm -f /tmp/verify-ecs-exec.bin'" >/dev/null 2>&1
echo ""

echo "=== 7. 失敗パターンが実物と同じ例外名で出るか ==="
expect_error() {
  local label="$1" expected="$2"; shift 2
  local out rc
  out=$(ee "$@")
  rc=$?
  if [[ ${rc} -eq 254 ]] && echo "${out}" | grep -q "${expected}"; then
    ok "${label} → ${expected} (exit 254)"
  else
    ng "${label}: ${expected} が出ない (rc=${rc})"
    echo "${out}" | sed 's/^/       /'
  fi
}

expect_error "存在しないクラスター" "ClusterNotFoundException" \
  aws ecs execute-command --cluster no-such-cluster --task "${TASK_ID}" \
  --container "${FRONT_CONTAINER}" --interactive --command "/bin/sh"

expect_error "タスクに無いコンテナ" "InvalidParameterException" \
  aws ecs execute-command --cluster "${CLUSTER}" --task "${TASK_ID}" \
  --container app-nowhere --interactive --command "/bin/sh"

expect_error "存在しないタスク ID" "InvalidParameterException" \
  aws ecs execute-command --cluster "${CLUSTER}" \
  --task ffffffffffffffffffffffffffffffff \
  --container "${FRONT_CONTAINER}" --interactive --command "/bin/sh"

expect_error "非対話モード" "Interactive is the only mode supported" \
  aws ecs execute-command --cluster "${CLUSTER}" --task "${TASK_ID}" \
  --container "${FRONT_CONTAINER}" --non-interactive --command "/bin/sh"

# --interactive を付け忘れたときは API ではなく CLI 側で弾かれる (exit 252)
NOI=$(ee aws ecs execute-command --cluster "${CLUSTER}" --task "${TASK_ID}" \
  --container "${FRONT_CONTAINER}" --command "/bin/sh")
NOI_RC=$?
[[ ${NOI_RC} -eq 252 ]] \
  && ok "--interactive の付け忘れ → 使い方エラー (exit 252)" \
  || ng "--interactive の付け忘れで exit 252 にならない (rc=${NOI_RC})"
echo ""

echo "=== 8. enableExecuteCommand を切ったときの挙動 ==="
ee aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" \
  --no-enable-execute-command >/dev/null
DISABLED=$(ee aws ecs describe-tasks --cluster "${CLUSTER}" --tasks "${TASK_ID}" \
  --query 'tasks[0].enableExecuteCommand' --output text | tr -d '\r')
[[ "${DISABLED}" == "False" ]] \
  && ok "update-service --no-enable-execute-command が反映された" \
  || ng "enableExecuteCommand が False にならない (${DISABLED})"

expect_error "exec 無効のまま実行" "execute command was not enabled" \
  aws ecs execute-command --cluster "${CLUSTER}" --task "${TASK_ID}" \
  --container "${FRONT_CONTAINER}" --interactive --command "/bin/sh"

ee aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" \
  --enable-execute-command >/dev/null
RESTORED=$(ee aws ecs describe-tasks --cluster "${CLUSTER}" --tasks "${TASK_ID}" \
  --query 'tasks[0].enableExecuteCommand' --output text | tr -d '\r')
[[ "${RESTORED}" == "True" ]] \
  && ok "--enable-execute-command で元に戻せた" \
  || ng "enableExecuteCommand を戻せない (${RESTORED})"
echo ""

echo "=== 9. 接続先が停止しているときの挙動 (TargetNotConnectedException) ==="
# adot-collector を一時的に止めて、エージェントに到達できない状態を作る
if docker inspect adot-collector >/dev/null 2>&1; then
  docker compose stop adot-collector >/dev/null 2>&1
  expect_error "停止中コンテナへの接続" "TargetNotConnectedException" \
    aws ecs execute-command --cluster "${CLUSTER}" --task "${TASK_ID}" \
    --container adot-collector --interactive --command "/bin/sh"
  AGENT_STOPPED=$(ee aws ecs describe-tasks --cluster "${CLUSTER}" --tasks "${TASK_ID}" \
    --query 'tasks[0].containers[2].managedAgents[0].lastStatus' --output text | tr -d '\r')
  [[ "${AGENT_STOPPED}" == "STOPPED" ]] \
    && ok "describe-tasks の ExecuteCommandAgent が STOPPED になった" \
    || ng "ExecuteCommandAgent が STOPPED にならない (${AGENT_STOPPED})"
  docker compose start adot-collector >/dev/null 2>&1
  info "adot-collector を起動し直しました"
else
  info "adot-collector が無いためこの確認は省略します"
fi
echo ""

echo "=== 10. セッションログ ==="
LOG_COUNT=$(ee sh -c 'find /var/log/ecs-exec -name "ecs-execute-command-*.log" | wc -l' | tr -d '\r ')
if [[ "${LOG_COUNT}" =~ ^[0-9]+$ ]] && [[ "${LOG_COUNT}" -gt 0 ]]; then
  ok "セッションログが ${LOG_COUNT} 件記録されている"
  info "出力先 (ホスト): ${SESSIONS_DIR}/<task-id>/<container>/<session-id>.log"
  ee ecs-exec sessions --limit 3 | sed 's/^/       /'
else
  ng "セッションログが記録されていない"
fi
echo ""

echo "============================================================"
echo "結果: OK ${OK_COUNT} 件 / NG ${FAIL_COUNT} 件"
if [[ ${FAIL_COUNT} -gt 0 ]]; then
  echo "詳細は docs/ECS-EXEC.md の「失敗パターンを再現する」を参照してください。"
  exit 1
fi
echo "ECS Exec の偽装は期待どおり動作しています。"
echo ""
echo "手元で対話シェルに入るには:"
echo "  docker compose exec ecs-exec aws ecs execute-command \\"
echo "    --cluster ${CLUSTER} --task ${TASK_ID} \\"
echo "    --container ${FRONT_CONTAINER} --interactive --command \"/bin/bash\""
