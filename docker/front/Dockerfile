# =============================================================================
# フロントコンテナ用 Dockerfile
# 前提:
#   - <EAP_BASE_IMAGE> は「UBI9 + Red Hat OpenJDK 21 + JBoss EAP 8.1 導入済み」の
#     社内標準ベースイメージ (JBOSS_HOME=/opt/server, ユーザー jboss(UID 185))。
#     例: eap-maven-plugin / Galleon で provision したサーバーを
#         registry.redhat.io/ubi9/openjdk-21-runtime に COPY 済みのイメージ。
#   - ビルドコンテキストはリポジトリの docker/ ディレクトリ
#     (docker build -f front/Dockerfile . を docker/ 直下で実行)
# =============================================================================
ARG EAP_BASE_IMAGE=<EAP_BASE_IMAGE>
ARG ADOT_JAVA_AGENT_VERSION=v2.11.5
# Aurora MySQL 8.4 / MySQL 8.4.7 互換ドライバ。module.xml の resource-root 名と一致必須
ARG MYSQL_CONNECTOR_VERSION=9.7.0

# --- Stage 1: ADOT Java Agent (公式配布イメージから jar のみ取得) -------------
FROM public.ecr.aws/aws-observability/adot-autoinstrumentation-java:${ADOT_JAVA_AGENT_VERSION} AS adot

# --- Stage 2: 本体 -------------------------------------------------------------
FROM ${EAP_BASE_IMAGE}
ARG MYSQL_CONNECTOR_VERSION
ENV JBOSS_HOME=/opt/server
USER root

# ADOT Java Agent jar を配置 (ビルド時同梱方式)
COPY --from=adot --chown=185:0 /javaagent.jar /opt/adot/aws-opentelemetry-agent.jar

# --- MySQL Connector/J を静的モジュールとして設置 ----------------------------
# module add による自動生成ではなく、明示的な module.xml + jar を
# ${JBOSS_HOME}/modules/com/mysql/main/ へ配置する (Connector/J 9.7.0)。
# 1) module.xml を配置 (依存 jakarta.transaction.api / resource-root を明示)
COPY modules/com/mysql/main/module.xml ${JBOSS_HOME}/modules/com/mysql/main/module.xml
# 2) ドライバ jar を module.xml の resource-root と同じ名前で取得
#    (社内リポジトリがある場合はそちらへ差し替え。チェックサム検証推奨)
RUN curl -fsSL -o "${JBOSS_HOME}/modules/com/mysql/main/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar" \
      "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_CONNECTOR_VERSION}/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar" \
 && test -f "${JBOSS_HOME}/modules/com/mysql/main/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar"

# ビルド時に JBoss CLI (embed-server) で JDBC ドライバ登録・XA データソース等を構成
COPY cli/mysql-xa-datasource.cli /tmp/config.cli
RUN "${JBOSS_HOME}/bin/jboss-cli.sh" --file=/tmp/config.cli \
 && rm -f /tmp/config.cli \
 && rm -rf "${JBOSS_HOME}/standalone/configuration/standalone_xml_history" \
 && chown -R 185:0 "${JBOSS_HOME}/standalone" "${JBOSS_HOME}/modules" \
 && chmod -R g=u "${JBOSS_HOME}/standalone"

# アプリケーション WAR を配備 (アプリコードは無改変。front/app/ に WAR を置く)
COPY --chown=185:0 front/app/ ${JBOSS_HOME}/standalone/deployments/

# Entrypoint
COPY --chown=185:0 front/entrypoint.sh /opt/bin/entrypoint.sh
RUN chmod 0755 /opt/bin/entrypoint.sh

USER 185
EXPOSE 8080
ENTRYPOINT ["/opt/bin/entrypoint.sh"]
