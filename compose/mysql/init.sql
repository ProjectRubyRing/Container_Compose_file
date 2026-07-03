-- ローカル検証用初期化 (Aurora 側では DBA 作業として同等の GRANT を実施すること)
-- 注意: パスワードは compose.yaml の MYSQL_USER/MYSQL_PASSWORD (.env) で作成される。
--       ここでは XA(2PC) に必要な権限付与のみ行う。

-- MySQL 8.0 では XA RECOVER の実行に XA_RECOVER_ADMIN 権限が必要。
-- JBoss EAP のトランザクションリカバリマネージャが XA RECOVER を発行するため必須。
GRANT XA_RECOVER_ADMIN ON *.* TO 'appuser'@'%';

-- 動作確認用のサンプルテーブル
CREATE TABLE IF NOT EXISTS appdb.tx_check (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  note VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

FLUSH PRIVILEGES;
