#!/usr/bin/env bash
# =============================================================================
# ローカル compose 構成の動作確認スクリプト
# =============================================================================
set -euo pipefail

echo "=== 1. コンテナ状態確認 ==="
docker compose ps

echo "=== 2. ADOT Collector ヘルスチェック (13133) ==="
docker compose exec adot-collector /healthcheck && echo "collector: OK"

echo "=== 3. OTLP エンドポイント疎通確認 (ホスト → 4318) ==="
# 空 POST でも 4318 が生きていれば HTTP 応答が返る (405/415 等でも疎通は OK)
curl -s -o /dev/null -w "OTLP http status: %{http_code}\n" \
  -X POST -H "Content-Type: application/x-protobuf" \
  http://localhost:4318/v1/traces --data-binary ""

echo "=== 4. フロント経由でリクエストを発生させる ==="
for i in 1 2 3; do
  curl -s -o /dev/null -w "front http status: %{http_code}\n" http://localhost:8080/
done

echo "=== 5. Collector がスパンを受信したかログで確認 ==="
docker compose logs --tail 50 adot-collector | grep -Ei "TracesExporter|spans" || \
  echo "WARN: スパン受信ログが見つかりません。アプリのリクエストパスと agent 起動ログを確認してください。"

echo "=== 6. JBoss EAP 側の agent 起動確認 ==="
docker compose logs app-front  | grep -i "opentelemetry" | head -5 || true
docker compose logs app-back   | grep -i "opentelemetry" | head -5 || true

echo "=== 7. XA データソースの確認 (front) ==="
docker compose exec app-front /opt/server/bin/jboss-cli.sh --connect \
  --controller=127.0.0.1:9990 \
  "/subsystem=datasources/xa-data-source=AppXADS:test-connection-in-pool" || \
  echo "WARN: XA 接続テスト失敗。DB_HOST/DB_USER/DB_PASSWORD と MySQL の起動状態を確認。"

echo "=== 8. MySQL 2 スキーマ (appdb/appuser, infdb/infuser) の初期化確認 ==="
# パスワードは mysql コンテナ内の環境変数 (compose.yaml 直書き) を使う
docker compose exec mysql sh -c 'mysql -uappuser -p"$MYSQL_PASSWORD" -e "SELECT 1" appdb >/dev/null' \
  && echo "appdb/appuser: OK" || echo "WARN: appdb/appuser で接続できません"
docker compose exec mysql sh -c 'mysql -uinfuser -p"$INFDB_PASSWORD" -e "SELECT 1" infdb >/dev/null' \
  && echo "infdb/infuser: OK" || \
  echo "WARN: infdb/infuser で接続できません。初期化は初回起動時のみ実行されるため、既存ボリュームがある場合は docker compose down -v で再作成してください。"

echo "=== 9. ECS メタデータモック (/task) の確認 ==="
curl -s "http://localhost:8380/v4/158d1c8083dd49d6b527399fd6414f5c-1234567890/task" \
  | grep -q '"TaskARN"' && echo "ecs-metadata-mock /task: OK" || \
  echo "WARN: ecs-metadata-mock から TaskARN を含む応答が得られません"

echo "=== 10. 偽装 EFS (/mnt/logs, /mnt/data) の権限確認 (UID 6301 / GID 6302) ==="
docker compose exec efs-mock stat -c "%n owner=%u:%g mode=%a" /mnt/efs/logs /mnt/efs/data \
  || echo "WARN: efs-mock で権限を確認できません"

echo "=== 11. front/back から偽装 EFS への書き込み確認 ==="
docker compose exec app-front sh -c \
  'echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [app-front] verify-local" >> /mnt/logs/app-front.log \
   && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) verify-local" >> /mnt/data/app-front-data.txt' \
  && echo "app-front → /mnt/logs, /mnt/data: OK" || echo "WARN: app-front から書き込めません"
docker compose exec app-back sh -c \
  'echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [app-back] verify-local" >> /mnt/logs/app-back.log \
   && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) verify-local" >> /mnt/data/app-back-data.txt' \
  && echo "app-back → /mnt/logs, /mnt/data: OK" || echo "WARN: app-back から書き込めません"
# 作成されたファイルの所有者確認 (setgid により GID は 6302 になるはず)
docker compose exec efs-mock ls -ln /mnt/efs/logs /mnt/efs/data || true

echo "=== 12. cwagent → cloudwatch-logs-mock (PutLogEvents) の送信偽装確認 ==="
echo "(cwagent の force_flush_interval=5s を待機中...)"
sleep 10
PUT_COUNT=$(curl -s -X POST http://localhost:8480/__admin/requests/count \
  -H "Content-Type: application/json" \
  -d '{"method":"POST","url":"/","headers":{"X-Amz-Target":{"equalTo":"Logs_20140328.PutLogEvents"}}}' \
  | sed -n 's/.*"count"[^0-9]*\([0-9][0-9]*\).*/\1/p')
if [[ "${PUT_COUNT:-0}" -gt 0 ]]; then
  echo "PutLogEvents 受信: ${PUT_COUNT} 件 (cloudwatch-logs-mock)"
  # 送信されたログ本文にマーカーが含まれるか確認 (journal の body を検索)
  curl -s "http://localhost:8480/__admin/requests" | grep -q "verify-local" \
    && echo "送信本文に verify-local マーカーを確認: OK" \
    || echo "NOTE: journal からマーカー本文は確認できませんでした (件数ベースでは受信済み)"
else
  echo "WARN: PutLogEvents が届いていません。docker compose logs cwagent を確認してください。"
fi

echo ""
echo "Jaeger UI でトレースを確認: http://localhost:16686  (Service: myapp-front / myapp-back)"
