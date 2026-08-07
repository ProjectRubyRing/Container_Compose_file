# =============================================================================
# バックコンテナ用 Dockerfile (フロントとの差分: WAR / entrypoint / EXPOSE 8180)
# ビルドコンテキストは docker/ 直下 (docker build -f back/Dockerfile .)
# =============================================================================
ARG EAP_BASE_IMAGE=<EAP_BASE_IMAGE>
ARG ADOT_JAVA_AGENT_VERSION=v2.11.5
# Aurora MySQL 8.4 / MySQL 8.4.7 互換ドライバ。module.xml の resource-root 名と一致必須
ARG MYSQL_CONNECTOR_VERSION=9.7.0

FROM public.ecr.aws/aws-observability/adot-autoinstrumentation-java:${ADOT_JAVA_AGENT_VERSION} AS adot

# -----------------------------------------------------------------------------
# 非同期処理チェーンの終端となる Java サーブレット (async-receiver.war) をビルドする。
# ALB(nginx) 経由で Lambda から POST される /async/receive を受ける。
# WAR はこのステージ内で maven がビルドし、最終イメージの deployments/ へコピーする
# (成果物 .war を git 管理せず、ローカルに maven も不要にするため)。
# -----------------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-21 AS warbuild
WORKDIR /build
COPY back/servlet/pom.xml /build/pom.xml
# 依存解決を先に行い、ソース変更時のビルドキャッシュを効かせる
RUN mvn -q -B -e dependency:go-offline
COPY back/servlet/src /build/src
RUN mvn -q -B -e package

# -----------------------------------------------------------------------------
# TLS 検証用サーブレット (tls-probe.war) をビルドする。
# back の JVM 自身から HTTPS の REST API (secure-api / ALB) を呼び出し、
# JVM トラストストアによる証明書検証が成功することを確認するための WAR。
# front/Dockerfile でも同じソース (docker/probe/) から同じ WAR をビルドしている。
# -----------------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-21 AS probebuild
WORKDIR /probe
COPY probe/pom.xml /probe/pom.xml
RUN mvn -q -B -e dependency:go-offline
COPY probe/src /probe/src
RUN mvn -q -B -e package

FROM ${EAP_BASE_IMAGE}
ARG MYSQL_CONNECTOR_VERSION
ENV JBOSS_HOME=/opt/server
USER root

COPY --from=adot --chown=185:0 /javaagent.jar /opt/adot/aws-opentelemetry-agent.jar

# --- MySQL Connector/J を静的モジュールとして設置 ----------------------------
# module add による自動生成ではなく、明示的な module.xml + jar を
# ${JBOSS_HOME}/modules/com/mysql/main/ へ配置する (Connector/J 9.7.0)。
COPY modules/com/mysql/main/module.xml ${JBOSS_HOME}/modules/com/mysql/main/module.xml
RUN curl -fsSL -o "${JBOSS_HOME}/modules/com/mysql/main/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar" \
      "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_CONNECTOR_VERSION}/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar" \
 && test -f "${JBOSS_HOME}/modules/com/mysql/main/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar"

# elytron-truststore.cli は自己証明書 (cacert.crt) を取り込む JBoss 側トラストストア
# を定義する (front と同一)。ストアの実体は entrypoint.sh が起動時に生成する。
COPY cli/mysql-xa-datasource.cli /tmp/config.cli
COPY cli/elytron-truststore.cli  /tmp/truststore.cli
RUN "${JBOSS_HOME}/bin/jboss-cli.sh" --file=/tmp/config.cli \
 && "${JBOSS_HOME}/bin/jboss-cli.sh" --file=/tmp/truststore.cli \
 && rm -f /tmp/config.cli /tmp/truststore.cli \
 && rm -rf "${JBOSS_HOME}/standalone/configuration/standalone_xml_history" \
 && chown -R 185:0 "${JBOSS_HOME}/standalone" "${JBOSS_HOME}/modules" \
 && chmod -R g=u "${JBOSS_HOME}/standalone"

COPY --chown=185:0 back/app/ ${JBOSS_HOME}/standalone/deployments/

# 非同期チェーンの受け口サーブレット (コンテキストルート /async → /async/receive)
COPY --from=warbuild --chown=185:0 /build/target/async-receiver.war ${JBOSS_HOME}/standalone/deployments/

# TLS 検証用サーブレット (コンテキストルート /tls-probe → /tls-probe/check)
COPY --from=probebuild --chown=185:0 /probe/target/tls-probe.war ${JBOSS_HOME}/standalone/deployments/

COPY --chown=185:0 back/entrypoint.sh /opt/bin/entrypoint.sh
RUN chmod 0755 /opt/bin/entrypoint.sh

USER 185
# 起動時 port-offset=100 のため HTTP は 8180
EXPOSE 8180
ENTRYPOINT ["/opt/bin/entrypoint.sh"]
