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

echo "=== 9. DB 接続の TLS が RDS Proxy 相当か (docs/RDS-PROXY-TLS.md) ==="

# 9-1) mysqld が自己署名証明書を自動生成していないこと。
#      自動生成のままだと MY-010068 (CA certificate ca.pem is self signed) が出る。
if docker compose logs mysql | grep -q "MY-010068"; then
  echo "WARN: MY-010068 (自己署名 CA) が出ています。pki-init の証明書が使われていません"
  echo "      → docker compose down -v で volume ごと作り直してください"
else
  echo "自己署名 CA の自動生成なし (MY-010068 が出ていない): OK"
fi

# 9-2) mysqld が提示する証明書が CA 発行で、SAN に接続先ホスト名 (mysql) を含むこと。
#      これが成立しないと sslMode=VERIFY_IDENTITY は張れない (= 本番と同じ検証ができない)。
docker compose exec -T mysql sh -c \
  'mysql --ssl-mode=VERIFY_IDENTITY --ssl-ca=/mnt/pki/ca/ca-chain.crt \
     -h mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -D"$MYSQL_DATABASE" -e "SELECT 1" >/dev/null' \
  && echo "VERIFY_IDENTITY (チェーン + ホスト名検証) で接続: OK" \
  || echo "WARN: VERIFY_IDENTITY で接続できません。rds-proxy 証明書の SAN を確認してください"

# 9-3) 平文接続が拒否されること (RDS Proxy の "Require TLS" 有効時と同じ挙動)。
#      ここで成功してしまう構成は、本番 RDS Proxy でだけ落ちる。
if docker compose exec -T mysql sh -c \
     'mysql --ssl-mode=DISABLED -h 127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1"' \
     >/dev/null 2>&1; then
  echo "WARN: 平文接続が通ってしまいます (require_secure_transport が効いていません)"
else
  echo "平文接続は拒否される (require_secure_transport=ON): OK"
fi

# 9-4) front/back が実際に張っている接続が TLS であること。
#      performance_schema.threads.CONNECTION_TYPE が SSL/TLS なら暗号化されている。
echo "-- appuser のコネクション種別 (SSL/TLS であること) --"
docker compose exec -T mysql sh -c \
  'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "
     SELECT PROCESSLIST_USER, CONNECTION_TYPE, COUNT(*)
     FROM performance_schema.threads
     WHERE PROCESSLIST_USER IS NOT NULL
     GROUP BY PROCESSLIST_USER, CONNECTION_TYPE"' \
  || echo "WARN: コネクション種別を取得できません"

echo "=== 10. ECS メタデータモック (/task) の確認 ==="
curl -s "http://localhost:8380/v4/158d1c8083dd49d6b527399fd6414f5c-1234567890/task" \
  | grep -q '"TaskARN"' && echo "ecs-metadata-mock /task: OK" || \
  echo "WARN: ecs-metadata-mock から TaskARN を含む応答が得られません"

echo "=== 11. 偽装 EFS (/mnt/logs, /mnt/data) の権限確認 (UID 6301 / GID 6302) ==="
docker compose exec efs-mock stat -c "%n owner=%u:%g mode=%a" /mnt/efs/logs /mnt/efs/data \
  || echo "WARN: efs-mock で権限を確認できません"

echo "=== 12. front/back から偽装 EFS への書き込み確認 ==="
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

echo "=== 13. cwagent のマウント/権限/設定パス評価 ==="
# cwagent のイメージは診断ツールが乏しく docker exec での確認が現実的でないため、
# (13-1) ホスト側の docker inspect と、
# (13-2) コンテナ内 entrypoint ラッパー (compose/cwagent/verify-mount.sh) の
#        自己診断レポートの 2 系統で評価する。

echo "-- 13-1) ホスト側から見たマウント適用状況 (docker inspect / exec 不要) --"
docker inspect cwagent \
  --format '{{range .Mounts}}  {{.Type}} src={{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}} dst={{.Destination}} rw={{.RW}}
{{end}}' 2>/dev/null || echo "WARN: cwagent を inspect できません (起動していない可能性)"

if docker inspect cwagent --format '{{range .Mounts}}{{.Destination}} {{end}}' 2>/dev/null \
   | tr ' ' '\n' | grep -qx "/mnt/logs"; then
  echo "cwagent に /mnt/logs がマウントされている (ホスト視点): OK"
else
  echo "WARN: cwagent に /mnt/logs のマウントがありません。compose.yaml の cwagent.volumes を確認してください"
fi

# 偽装 EFS の named volume を front/back/cwagent が共有できているか (同一 volume 名か)
echo "-- efs-logs volume を参照しているコンテナ --"
for c in app-front app-back cwagent efs-mock; do
  vols=$(docker inspect "$c" --format '{{range .Mounts}}{{if .Name}}{{.Name}}:{{.Destination}} {{end}}{{end}}' 2>/dev/null || true)
  echo "  ${c}: ${vols:-<取得できず>}"
done

echo "-- 13-2) コンテナ内 自己診断レポート ([cwagent-verify]) --"
# ラッパーは起動直後 ([boot]) と、アプリのログ書き込み後 ([recheck N]) に評価を出力する
CWA_REPORT=$(docker compose logs --no-color cwagent 2>/dev/null | grep -F "[cwagent-verify]" || true)
if [[ -z "${CWA_REPORT}" ]]; then
  echo "WARN: 自己診断レポートが出力されていません。"
  echo "      compose.yaml の cwagent.entrypoint と compose/cwagent/verify-mount.sh のマウントを確認してください。"
else
  # 直近 1 回分 (最後の診断ブロック) だけを表示する
  echo "${CWA_REPORT}" | awk '/cwagent mount\/permission diagnostics/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}'

  # FAIL 行は必ず抜き出して目立たせる (RESULT: FAIL 行は除くため "] FAIL " で絞る)
  # docker compose logs のサービス名プレフィクスごと落として重複を除去する
  CWA_FAILS=$(echo "${CWA_REPORT}" | grep -F "] FAIL " || true)
  if [[ -n "${CWA_FAILS}" ]]; then
    echo "-- 検出された FAIL (重複除去) --"
    echo "${CWA_FAILS}" | sed 's/.*\[cwagent-verify\]\[[^]]*\] *//' | sort -u | sed 's/^/  /'
  fi

  CWA_LAST=$(echo "${CWA_REPORT}" | grep -F "RESULT:" | tail -n 1 || true)
  case "${CWA_LAST}" in
    *"RESULT: PASS"*) echo "cwagent 自己診断 (最新): PASS" ;;
    *"RESULT: WARN"*) echo "cwagent 自己診断 (最新): WARN — 上記 WARN 行を確認してください" ;;
    *"RESULT: FAIL"*) echo "WARN: cwagent 自己診断 (最新) が FAIL です。上記 FAIL 行が送信失敗の原因の可能性が高いです" ;;
    *)                echo "NOTE: RESULT 行を取得できませんでした" ;;
  esac
fi

echo "=== 14. cwagent → cloudwatch-logs-mock (PutLogEvents) 送信の深堀 ==="
echo "(cwagent の force_flush_interval=5s を待機中...)"
sleep 10

# WireMock の request journal を API アクション別に集計する
journal_count() {
  curl -s -X POST http://localhost:8480/__admin/requests/count \
    -H "Content-Type: application/json" \
    -d "{\"method\":\"POST\",\"url\":\"/\",\"headers\":{\"X-Amz-Target\":{\"equalTo\":\"$1\"}}}" \
    | sed -n 's/.*"count"[^0-9]*\([0-9][0-9]*\).*/\1/p'
}

echo "-- 14-1) API アクション別の受信件数 (cloudwatch-logs-mock) --"
for action in CreateLogGroup CreateLogStream DescribeLogGroups DescribeLogStreams PutLogEvents; do
  cnt=$(journal_count "Logs_20140328.${action}" || true)
  printf '  %-20s : %s 件\n' "${action}" "${cnt:-0}"
done

PUT_COUNT=$(journal_count "Logs_20140328.PutLogEvents" || true)
PUT_COUNT="${PUT_COUNT:-0}"

if [[ "${PUT_COUNT}" -gt 0 ]]; then
  echo "PutLogEvents 受信: ${PUT_COUNT} 件 (cloudwatch-logs-mock): OK"
  curl -s "http://localhost:8480/__admin/requests" | grep -q "verify-local" \
    && echo "送信本文に verify-local マーカーを確認: OK" \
    || echo "NOTE: journal からマーカー本文は確認できませんでした (件数ベースでは受信済み)"
else
  echo "WARN: PutLogEvents が届いていません。以下で切り分けます。"

  # 14-2) マウント/設定パス側の問題か (13-2 の自己診断で判定済みの内容を再掲)
  echo "-- 14-2) マウント/設定パスの評価 --"
  if echo "${CWA_REPORT:-}" | grep -qF "マウント成立"; then
    echo "  /mnt/logs のマウントは成立している → 原因はマウント以外の可能性が高い"
  else
    echo "  /mnt/logs のマウントが確認できない → まず compose.yaml の cwagent.volumes を修正すること"
  fi
  if echo "${CWA_REPORT:-}" | grep -qF "glob に一致するファイルが 0 件"; then
    echo "  設定の file_path に一致するファイルが 0 件 → アプリの出力先と cwagent-config.json の"
    echo "  file_path が食い違っている (docker/{front,back}/entrypoint.sh の出力パスを確認)"
  fi
  if echo "${CWA_REPORT:-}" | grep -qF "読み取り不可 (open 失敗)"; then
    echo "  ファイルを open できていない → 6301:6302 の権限か cwagent の group_add を確認すること"
  fi

  # 14-3) エージェントがファイルを検知したか (tail オフセットの state ファイル)
  echo "-- 14-3) エージェントのファイル検知状況 --"
  if echo "${CWA_REPORT:-}" | grep -qF "tail 状態ファイルあり"; then
    echo "  ファイル検知済み (state あり) → 検知は成功。送信 (HTTP/署名) 側を疑う"
  else
    echo "  ファイル未検知 (state なし) → 設定の file_path / 権限側を疑う"
  fi

  # 14-4) エージェントログのエラー抽出
  echo "-- 14-4) cwagent ログのエラー行 (末尾 30 行) --"
  CWA_ERRORS=$(docker compose logs --no-color cwagent 2>/dev/null \
    | grep -Ei "no such file|permission denied|cannot open|connection refused|no valid credential|NoCredentialProviders|RequestError|InvalidSignature|SerializationException|AccessDenied|ResourceNotFound|panic|E! " \
    | tail -n 30 || true)
  if [[ -n "${CWA_ERRORS}" ]]; then
    echo "${CWA_ERRORS}" | sed 's/^/  /'
  else
    echo "  (該当するエラー行なし)"
  fi

  # 14-5) WireMock 側で未マッチのリクエストが無いか (スタブ定義漏れの検出)
  echo "-- 14-5) cloudwatch-logs-mock の未マッチリクエスト --"
  UNMATCHED=$(curl -s http://localhost:8480/__admin/requests/unmatched 2>/dev/null \
    | sed -n 's/.*"count"[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n 1 || true)
  echo "  unmatched: ${UNMATCHED:-0} 件"
  if [[ "${UNMATCHED:-0}" -gt 0 ]]; then
    echo "  → compose/cloudwatch-logs-mock/mappings/ のスタブ定義が不足しています"
  fi

  echo "詳細: docker compose logs cwagent | grep cwagent-verify"
fi

echo ""
echo "Jaeger UI でトレースを確認: http://localhost:16686  (Service: myapp-front / myapp-back)"
