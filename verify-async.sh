#!/usr/bin/env bash
# =============================================================================
# 非同期処理チェーン (SQS → lambda-esm → Lambda → ALB → app-back) の動作確認
#   詳細は docs/ASYNC-SQS-LAMBDA-ALB.md を参照
# =============================================================================
set -euo pipefail

SQS_URL="http://localhost:9324"
QUEUE_NAME="app-async-queue"
QUEUE_URL="${SQS_URL}/000000000000/${QUEUE_NAME}"
DLQ_URL="${SQS_URL}/000000000000/app-async-dlq"
ALB_URL="http://localhost:9080"
LAMBDA_URL="http://localhost:9000/2015-03-31/functions/function/invocations"

echo "=== 1. 関連コンテナの状態確認 ==="
docker compose ps sqs lambda lambda-esm alb app-back

echo "=== 2. ElasticMQ (SQS) の疎通確認 ==="
curl -s -o /dev/null -w "elasticmq stats http status: %{http_code}\n" "http://localhost:9325/statistics" || \
  echo "WARN: ElasticMQ 統計エンドポイントに疎通できません"

echo "=== 3. ALB (nginx) ヘルスチェック ==="
curl -s -w " (status: %{http_code})\n" "${ALB_URL}/healthz" || \
  echo "WARN: ALB /healthz に疎通できません"

echo "=== 4. ALB 経由で app-back サーブレットへ直接 POST (Lambda を介さない疎通確認) ==="
curl -s -w "\n(status: %{http_code})\n" -X POST "${ALB_URL}/async/receive" \
  -H 'Content-Type: application/json' \
  -d '{"probe":"via-alb-direct"}' || \
  echo "WARN: ALB→app-back の直接 POST に失敗"

echo "=== 5. Lambda を直接 invoke (RIE。SQS を介さない疎通確認) ==="
curl -s -w "\n(status: %{http_code})\n" -X POST "${LAMBDA_URL}" \
  -d '{"Records":[{"messageId":"probe-1","body":"{\"probe\":\"direct-invoke\"}"}]}' || \
  echo "WARN: Lambda 直接 invoke に失敗"

echo "=== 6. SQS にメッセージを投入 (プロデューサ = app-front/app-back 相当) ==="
BODY='{"orderId":"A-1001","action":"createReport","ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
if command -v aws >/dev/null 2>&1; then
  aws --endpoint-url "${SQS_URL}" --region ap-northeast-1 sqs send-message \
    --queue-url "${QUEUE_URL}" --message-body "${BODY}" \
    && echo "send-message (awscli): OK"
else
  # awscli が無くても ElasticMQ の query API で投入できる
  curl -s -o /dev/null -w "send-message (query API) http status: %{http_code}\n" \
    "${QUEUE_URL}" \
    --data-urlencode "Action=SendMessage" \
    --data-urlencode "Version=2012-11-05" \
    --data-urlencode "MessageBody=${BODY}"
fi

echo "=== 7. poller → Lambda → ALB → app-back の伝搬を待機 (最大 25s) ==="
sleep 5
docker compose logs --tail 10 lambda-esm | grep -Ei "received|invoking|deleted" || \
  echo "NOTE: lambda-esm のログにまだ受信記録がありません"

echo "=== 8. Lambda が処理したか (docker logs lambda) ==="
docker compose logs --tail 10 lambda | grep -Ei "lambda_handler|received" || \
  echo "NOTE: lambda の処理ログが見つかりません"

echo "=== 9. ALB のアクセスログに /async/receive があるか ==="
docker compose logs --tail 20 alb | grep -Ei "/async/receive" || \
  echo "NOTE: ALB に /async/receive の記録がありません"

echo "=== 10. app-back の Java サーブレットが受信したか ==="
docker compose logs --tail 30 app-back | grep -Ei "async-receiver" | tail -5 || \
  echo "NOTE: app-back に async-receiver の受信ログがありません"

echo "=== 11. 正常処理されたメッセージがキューから消えたか ==="
sleep 3
if command -v aws >/dev/null 2>&1; then
  aws --endpoint-url "${SQS_URL}" --region ap-northeast-1 sqs get-queue-attributes \
    --queue-url "${QUEUE_URL}" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
else
  curl -s "${QUEUE_URL}" \
    --data-urlencode "Action=GetQueueAttributes" \
    --data-urlencode "Version=2012-11-05" \
    --data-urlencode "AttributeName.1=ApproximateNumberOfMessages" \
    | grep -Eo '<Value>[0-9]+</Value>' | head -1 \
    && echo "(ApproximateNumberOfMessages ↑ が 0 なら処理完了)"
fi

echo "=== 12. DLQ (app-async-dlq) の滞留確認 (0 件が正常) ==="
if command -v aws >/dev/null 2>&1; then
  aws --endpoint-url "${SQS_URL}" --region ap-northeast-1 sqs get-queue-attributes \
    --queue-url "${DLQ_URL}" --attribute-names ApproximateNumberOfMessages
else
  echo "(awscli があれば DLQ 件数も確認できます)"
fi

echo "=== 13. メンテナンス Lambda を直接 invoke (RIE) ==="
curl -s -w "\n(status: %{http_code})\n" -X POST \
  "http://localhost:9001/2015-03-31/functions/function/invocations" \
  -d '{"httpMethod":"GET","path":"/maintenance","headers":{},"body":""}' \
  | head -3 || echo "WARN: メンテナンス Lambda の直接 invoke に失敗"

echo "=== 14. ALB のリスナールール経由でメンテナンス画面を取得 (/maintenance) ==="
echo "(HTTP ステータスとヘッダのみ表示。503 + X-Maintenance:true が期待値)"
curl -s -o /dev/null -D - "${ALB_URL}/maintenance" \
  | grep -Ei '^HTTP/|^x-maintenance|^retry-after|^content-type' \
  || echo "WARN: ALB 経由でメンテナンス画面を取得できません"

echo ""
echo "完了:"
echo "  - 上記 10 で app-back のサーブレットが body を受信していれば非同期 E2E 成功。"
echo "  - 上記 14 で 503 + X-Maintenance ヘッダが返れば メンテナンス Lambda 経路 成功。"
echo "  - 全面メンテナンス切り替えは ./alb-maintenance.sh on|off で確認できます。"
