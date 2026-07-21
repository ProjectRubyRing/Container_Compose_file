# Aurora MySQL 8.4 / MySQL 8.4.7 化ガイド — 8.0.42 との違いと Connector/J 9.7.0

本ドキュメントは、ローカル compose の DB を **`mysql:8.0.42` から `mysql:8.4.7`** へ、
JBoss EAP 8.1 (app-front / app-back) の JDBC ドライバを **Connector/J 8.4.0 から 9.7.0** へ
更新したことによる、**コンテナの取り扱い**と**接続まわりの差分**を、できるだけ具体的に説明する。

対象読者は、このリポジトリで compose 検証を行う開発者、および ECS/Aurora へ展開する運用担当。

- 本番: **Aurora MySQL 8.4**（Aurora MySQL バージョン 3.10 系以降が MySQL 8.4 互換）+ RDS Proxy
- ローカル: **コミュニティ版 `mysql:8.4.7`**（Aurora 8.4 の挙動をローカルで模擬）

> ⚠️ **結論から**: アプリのコード・WAR・XA データソースの JNDI/接続プロパティは**無改変**。
> 変わったのは「DB イメージのタグ」「Connector/J のバージョンと配置方式（静的 module.xml）」の 2 点。
> 初期セットアップ（appdb/appuser・infdb/infuser の 2 スキーマ、`XA_RECOVER_ADMIN` 付与、
> サンプルテーブル）は **8.0.42 のときと完全に同一**。

---

## 0. 何を変えたか（差分サマリ）

| 対象 | 変更前 | 変更後 |
|---|---|---|
| DB イメージ | `mysql:8.0.42` | `mysql:8.4.7` |
| 想定本番 DB | Aurora MySQL（8.0 系） | **Aurora MySQL 8.4** |
| Connector/J | 8.4.0 | **9.7.0** |
| ドライバ配置方式 | CLI の `module add` で module.xml を**自動生成** | **明示的な `module.xml` + jar を静的配置** |
| module.xml の場所 | （自動生成・非管理） | `docker/modules/com/mysql/main/module.xml`（レビュー可能） |
| 初期化 SQL/スキーマ | init.sql / init-infdb.sh | **同一（変更なし）** |
| XA データソース設定 | mysql-xa-datasource.cli | **接続プロパティは同一**（`module add` 行のみ削除） |

変更したファイル:

- `compose.yaml` … `image: mysql:8.4.7` に変更（コメントも更新）
- `docker/front/Dockerfile` / `docker/back/Dockerfile` … `MYSQL_CONNECTOR_VERSION=9.7.0`、
  ドライバを module ディレクトリへ静的配置
- `docker/cli/mysql-xa-datasource.cli` … `module add` を削除（静的モジュール前提）
- `docker/modules/com/mysql/main/module.xml` … **新規**。Connector/J 9.7.0 のモジュール定義

---

## 1. コンテナの取り扱いの差分（8.0.42 → 8.4.7）

### 1.1 イメージのタグを変えるだけで初期化は同じ

公式 `mysql` イメージのエントリポイント（`docker-entrypoint.sh`）の仕様は 8.0 と 8.4 で共通のため、
以下は **8.4.7 でもそのまま同じ挙動**になる。

- `MYSQL_DATABASE` / `MYSQL_USER` / `MYSQL_PASSWORD` による appdb/appuser の自動作成
- `/docker-entrypoint-initdb.d/` 配下の `*.sql` / `*.sh` を**初回起動時のみ**実行
  （`10-init.sql` → `20-init-infdb.sh` の順、拡張子・ファイル名順）
- `mysql-data` という named volume に `/var/lib/mysql` を永続化

したがって init.sql / init-infdb.sh は無改変で動作する。

### 1.2 【最重要】既存 volume は 8.0 → 8.4 で「そのままでは」使えない

MySQL は**メジャー/マイナーをまたぐダウングレードを許さず**、アップグレードは
**サーバ起動時にデータディクショナリを自動アップグレード**する（`mysql_upgrade` は 8.0 以降サーバに内蔵）。

ローカル compose で **8.0.42 時代に作られた `mysql-data` volume が残ったまま** 8.4.7 を起動すると、
バージョン境界をまたぐ起動になり、次のいずれかが起こり得る:

- 自動アップグレードが走る（多くの場合は成功するが、起動が一時的に遅くなる）
- 互換性の都合で**起動に失敗**する（特に一度 8.4 で起動した volume を 8.0 に戻すと確実に失敗）

**ローカル検証では「初期化し直す」のが最も確実**。データを捨てて作り直す:

```bash
# DB だけ作り直す（他サービスは残す）
docker compose down
docker volume rm eap-adot-local_mysql-data   # ← プロジェクト名 eap-adot-local + volume 名
docker compose up -d --build mysql
docker compose logs -f mysql                 # init スクリプトが再実行されることを確認
```

> volume を消すと `/docker-entrypoint-initdb.d/` が**再実行**され、appdb/infdb が作り直される。
> つまり「初期セットアップ内容は 8.0.42 と同じ」ことがそのまま担保される。

本番 Aurora では、この「volume の作り直し」に相当するのは
**Aurora のメジャーバージョンアップグレード（3.x への引き上げ）**であり、
スナップショット取得 → アップグレード → 検証、という別手順になる（後述 3 章）。

### 1.3 認証プラグインの既定変更（8.4 の最重要ポイント）

| | MySQL 8.0.42 | MySQL 8.4.7 / Aurora 8.4 |
|---|---|---|
| 既定認証プラグイン | `caching_sha2_password` | `caching_sha2_password`（同じ） |
| `mysql_native_password` | **有効**（利用可能） | **既定で無効化**（プラグインはあるが `OFF`） |
| `default_authentication_plugin` 変数 | 存在（非推奨） | **削除**（指定するとサーバが起動しない） |

本リポジトリの初期化は認証プラグインを一切指定しないため、appuser/infuser は
8.0 でも 8.4 でも `caching_sha2_password` で作成され、**差は出ない**。
ただし次の点に注意:

- もし過去に `mysql_native_password` を明示していた設定・スクリプトがあると、
  8.4 では**そのユーザ作成やログインが失敗**する。本リポジトリには該当箇所は無い。
- `my.cnf` などに `default_authentication_plugin=...` を書くと **8.4 サーバは起動しない**。
  追加してはいけない（8.0 時代のチューニング資産を流用する場合の落とし穴）。

`caching_sha2_password` は**平文接続の初回認証時**にサーバ公開鍵の取得を要するが、
本構成は XA データソースが `SslMode=PREFERRED`（既定）で **TLS 接続**するため問題にならない
（TLS 上では公開鍵交換が不要）。この挙動も 8.0 と 8.4 で同じ。詳細は 2 章。

### 1.4 healthcheck・管理コマンドは同じ

`mysqladmin ping -h 127.0.0.1 -uroot -p...` による healthcheck は 8.4.7 でも同一に動作する。
`mysql --protocol=socket` を使う `init-infdb.sh` も同じ。**変更不要**。

### 1.5 起動時間・リソース

8.4 は 8.0 と比べ、初回起動時のデータディクショナリ初期化やリドゥログの扱いが多少変わるが、
compose の `start_period: 30s` / `retries: 10` の範囲で収まる。既存 volume からの自動アップグレードが
走る初回だけは余裕を見ること（1.2 の作り直しを推奨）。

---

## 2. 接続まわりの差分（Connector/J 8.4.0 → 9.7.0、および 8.4 サーバ接続）

### 2.1 Connector/J 9.x を選ぶ理由

- MySQL 8.4（および Aurora MySQL 8.4）は **Connector/J 9.x 系**が正式対応。
  8.4.0 でも接続自体は可能だが、8.4 サーバの新機能・非推奨対応・バグ修正を取り込むため 9.7.0 を採用。
- Connector/J 9.x の要件: **JDK 8 は非対応、JDK 21 で動作**。本イメージは OpenJDK 21 のため適合。
- ドライバクラス名は不変（`com.mysql.cj.jdbc.MysqlXADataSource` / `com.mysql.cj.jdbc.Driver`）。
  よって **XA データソースの `driver-xa-datasource-class-name` は無改変**。

### 2.2 ドライバ配置を「静的 module.xml」に変えた（module.xml 他必要ファイルの設置）

**変更前**は CLI 内で以下を実行し、module.xml を JBoss に**自動生成**させていた:

```
module add --name=com.mysql --resources=/tmp/mysql-connector-j.jar --dependencies=jakarta.transaction.api
```

**変更後**は、明示的な `module.xml` と jar を JBoss のモジュールツリーへ**静的配置**する。
これにより「どの jar を・どの依存で・どうエクスポートするか」がファイルとしてレビュー可能になる。

配置レイアウト（最終イメージ内、front/back 共通）:

```
${JBOSS_HOME}/modules/
└── com/
    └── mysql/
        └── main/
            ├── module.xml                       ← リポジトリ docker/modules/... から COPY
            └── mysql-connector-j-9.7.0.jar       ← Dockerfile がビルド時に取得
```

`module.xml` の要点（`docker/modules/com/mysql/main/module.xml`）:

```xml
<module xmlns="urn:jboss:module:1.9" name="com.mysql">
    <resources>
        <resource-root path="mysql-connector-j-9.7.0.jar"/>
    </resources>
    <dependencies>
        <module name="jakarta.transaction.api"/>
    </dependencies>
</module>
```

- `name="com.mysql"` … CLI の `driver-module-name=com.mysql` と一致（**JNDI/データソースからの参照名**）。
- `resource-root path` … jar のファイル名。**Dockerfile の `MYSQL_CONNECTOR_VERSION` と必ず一致**させる。
- `jakarta.transaction.api` … EAP 8（Jakarta EE 10）で **XA/2PC** に必要な依存。
  EAP 7 系の `javax.transaction.api` に相当する（名前空間が `javax` → `jakarta` へ移行済み）。
- `java.sql`（JDBC API）は JDK 提供モジュールとして自動可視のため明示不要。

Dockerfile 側（front/back とも同一）:

```dockerfile
ARG MYSQL_CONNECTOR_VERSION=9.7.0
COPY modules/com/mysql/main/module.xml ${JBOSS_HOME}/modules/com/mysql/main/module.xml
RUN curl -fsSL -o "${JBOSS_HOME}/modules/com/mysql/main/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar" \
      "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_CONNECTOR_VERSION}/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar" \
 && test -f "${JBOSS_HOME}/modules/com/mysql/main/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar"
```

> **ドライバを更新するときの手順**（例: 9.7.0 → 9.8.0）:
> 1. `module.xml` の `<resource-root path="mysql-connector-j-9.8.0.jar"/>` を書き換える
> 2. front/back Dockerfile の `ARG MYSQL_CONNECTOR_VERSION=9.8.0` を書き換える
> 3. `docker compose build --no-cache app-front app-back` で再ビルド
>
> この 2 ファイルの版数がずれると、`test -f` で**ビルドが失敗**して気付けるようにしてある。

### 2.3 CLI から `module add` を除いた点

`docker/cli/mysql-xa-datasource.cli` は**モジュールが既に配置済み**であることを前提に、
`jdbc-driver` の登録から開始する。それ以外（XA データソース、接続プロパティ、node-identifier）は**無改変**:

```
/subsystem=datasources/jdbc-driver=mysql:add(
    driver-name=mysql,
    driver-module-name=com.mysql,
    driver-xa-datasource-class-name=com.mysql.cj.jdbc.MysqlXADataSource )
```

Java アプリからの利用方法も従来どおり。JNDI `java:jboss/datasources/AppXADS` を lookup すれば
Connector/J 9.7.0 経由で Aurora 8.4 / MySQL 8.4.7 に XA 接続できる（アプリコードの変更は不要）。

### 2.4 TLS / 認証まわり（8.4 サーバへの接続で押さえる点）

XA データソースは `SslMode=${env.DB_SSL_MODE:PREFERRED}` で接続する（`mysql-xa-datasource.cli`）。

| 項目 | 説明 |
|---|---|
| `caching_sha2_password` | 8.4 の既定。**TLS 接続なら公開鍵交換が不要**で透過的に成功。本構成は PREFERRED で TLS が張られるため OK |
| 平文接続にしたい場合 | `allowPublicKeyRetrieval=true` が別途必要になる。ローカルで TLS を切るときの注意点（通常は不要） |
| `mysql_native_password` | 8.4 では既定 OFF。**このプラグインに依存した接続文字列/ユーザは使わない**こと |
| Aurora + RDS Proxy | 本番は要件に応じ `SslMode=VERIFY_IDENTITY`（サーバ証明書＋ホスト名検証）へ。`DB_SSL_MODE` 環境変数で切替可能 |
| Connector/J 9.x の TLS | 旧 `useSSL` / `verifyServerCertificate` は非推奨。`sslMode`（本構成が使用）に統一されている |

### 2.5 XA / 2PC は 8.0 と同じ考慮がそのまま必要

Connector/J・サーバの版が上がっても、MySQL の XA 仕様と JBoss リカバリの要件は不変:

- `PinGlobalTxToPhysicalConnection=true` … 同一 XID の `XA START`〜`XA PREPARE` を同一物理接続で行う制約への対策（必須）
- `XA_RECOVER_ADMIN` … `XA RECOVER` 発行に必要。init.sql / init-infdb.sh で付与済み（8.4 でも同じ権限名）
- `node-identifier`（`TX_NODE_ID`）… 同一 DB を共有する全 EAP で一意化（重複すると他ノードの in-doubt を誤ロールバック）

これらは DESIGN.md 2.5 / 4 章（トラブルシューティング）と同じ。**8.4 化による追加対応は不要**。

---

## 3. 本番 Aurora MySQL 8.4 への展開時の注意（参考）

ローカルの `mysql:8.4.7` は Aurora 8.4 の**挙動確認用の代替**。本番 Aurora を 8.4 化する際は別作業:

1. **アップグレード経路**: Aurora MySQL 2.x（MySQL 5.7 互換）からは 3.x（8.0 互換）を経て 8.4 互換版へ。
   既に 3.x なら 8.4 互換のマイナー（3.10 系以降）へのアップグレードで到達する。
2. **事前作業**: スナップショット取得、`pre-upgrade` チェック、パラメータグループの見直し
   （`default_authentication_plugin` を設定していれば**削除**。8.4 では未対応パラメータで起動不可）。
3. **認証**: 8.0 時代に `mysql_native_password` で作成したユーザがあれば、
   `caching_sha2_password` へ移行（`ALTER USER ... IDENTIFIED WITH caching_sha2_password ...`）。
   本リポジトリの appuser/infuser は元から `caching_sha2_password` のため移行不要。
4. **RDS Proxy**: 8.4 対応の Proxy 設定・エンジン互換を確認。XA のセッションピン留めメトリクス
   （`DatabaseConnectionsCurrentlySessionPinned`）を引き続き監視。
5. **DBA 作業**: `GRANT XA_RECOVER_ADMIN ON *.* TO ...` を appuser/infuser 相当に付与（init.sql と同等）。

---

## 4. 動作確認手順（ローカル）

```bash
# 1) 既存 DB volume を作り直して 8.4.7 をクリーン初期化（1.2 参照）
docker compose down
docker volume rm eap-adot-local_mysql-data 2>/dev/null || true

# 2) DB とアプリを再ビルド起動（Connector/J 9.7.0 が同梱される）
docker compose up -d --build mysql app-back app-front

# 3) サーバのバージョンが 8.4.7 か確認
docker compose exec mysql mysql -uroot -p"localdev-root-change-me" -e "SELECT VERSION();"
#   → 8.4.7 と表示されること

# 4) 2 スキーマと権限が初期化されているか（8.0.42 のときと同じ結果）
docker compose exec mysql mysql -uroot -p"localdev-root-change-me" \
  -e "SHOW DATABASES; SELECT user,host,plugin FROM mysql.user WHERE user IN ('appuser','infuser');"
#   → appdb / infdb が存在、plugin は caching_sha2_password

# 5) アプリ（app-front/app-back）が XA データソースで接続できているか
docker compose logs app-back | grep -i -E "datasource|AppXADS|WFLYJCA"
#   → AppXADS のバインド成功ログが出ること（Connector/J 9.7.0 経由）

# 6) 既存の総合確認スクリプト
./verify-local.sh
```

問題が出たときは:

- **app 起動時に `Cannot load module com.mysql` / driver 未検出** → `module.xml` の
  `<resource-root path>` と Dockerfile の `MYSQL_CONNECTOR_VERSION`（jar 名）が一致しているか。
- **mysql が起動しない/ループ再起動** → 8.0 時代の `mysql-data` volume が残存（1.2 の作り直し）。
- **認証エラー（`Public Key Retrieval is not allowed` 等）** → 平文接続時のみ発生。
  `SslMode=PREFERRED`（既定）で TLS を張れば解消（2.4 参照）。
