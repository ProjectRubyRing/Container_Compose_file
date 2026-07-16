#!/usr/bin/env bash
# =============================================================================
# infdb / infuser の初期化 (ローカル検証用)
# appdb / appuser は公式イメージの MYSQL_DATABASE / MYSQL_USER で作成されるため、
# 2 つ目のスキーマはこのスクリプトで作成する。
# パスワードは compose.yaml の INFDB_PASSWORD 環境変数 (.env) から注入される。
# (Aurora 側では DBA 作業として同等の CREATE/GRANT を実施すること)
# =============================================================================
set -euo pipefail

mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS infdb CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

CREATE USER IF NOT EXISTS 'infuser'@'%' IDENTIFIED BY '${INFDB_PASSWORD}';
GRANT ALL PRIVILEGES ON infdb.* TO 'infuser'@'%';

-- appuser と同様、JBoss EAP のトランザクションリカバリ (XA RECOVER) 用
GRANT XA_RECOVER_ADMIN ON *.* TO 'infuser'@'%';

-- 動作確認用のサンプルテーブル
CREATE TABLE IF NOT EXISTS infdb.tx_check (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  note VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

FLUSH PRIVILEGES;
SQL

echo "init-infdb.sh: infdb / infuser created"
