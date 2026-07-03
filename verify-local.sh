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

echo ""
echo "Jaeger UI でトレースを確認: http://localhost:16686  (Service: myapp-front / myapp-back)"
