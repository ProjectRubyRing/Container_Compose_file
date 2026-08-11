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

# -----------------------------------------------------------------------------
# Stage 1b: TLS 検証用サーブレット (tls-probe.war) をビルドする。
# front の JVM 自身から HTTPS の REST API (secure-api / ALB) を呼び出し、
# JVM トラストストアによる証明書検証が成功することを確認するための WAR。
# back/Dockerfile でも同じソースから同じ WAR をビルドして配備している。
# -----------------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-21 AS probebuild
WORKDIR /probe
COPY probe/pom.xml /probe/pom.xml
RUN mvn -q -B -e dependency:go-offline
COPY probe/src /probe/src
RUN mvn -q -B -e package

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

# ビルド時に JBoss CLI (embed-server) で JDBC ドライバ登録・XA データソース等を構成。
# elytron-truststore.cli は自己証明書 (cacert.crt) を取り込む JBoss 側トラストストア
# (key-store / trust-manager / client-ssl-context) を定義する。ストアの実体は
# entrypoint.sh が起動時に ${PKI_TRUST_DIR}/*.crt から生成する。
COPY cli/mysql-xa-datasource.cli /tmp/config.cli
COPY cli/elytron-truststore.cli  /tmp/truststore.cli
RUN "${JBOSS_HOME}/bin/jboss-cli.sh" --file=/tmp/config.cli \
 && "${JBOSS_HOME}/bin/jboss-cli.sh" --file=/tmp/truststore.cli \
 && rm -f /tmp/config.cli /tmp/truststore.cli \
 && rm -rf "${JBOSS_HOME}/standalone/configuration/standalone_xml_history" \
 && chown -R 185:0 "${JBOSS_HOME}/standalone" "${JBOSS_HOME}/modules" \
 && chmod -R g=u "${JBOSS_HOME}/standalone"

# -----------------------------------------------------------------------------
# ★自己証明書 (cacert.crt) のビルド時取り込み — BuildKit の build secret 経由
# -----------------------------------------------------------------------------
# 社内標準ベースイメージが行っているのと同じ方式をこのイメージでも再現している。
# pki-init が出力した cacert.crt (compose/pki/export/cacert.crt) を secret として
# 渡すと、ここで JVM と JBoss EAP の両トラストストアへ焼き込む。
#
#   docker compose -f compose.yaml -f compose.build-secret.yaml build app-front
#   docker build --secret id=cacert,src=compose/pki/export/cacert.crt -f front/Dockerfile .
#
# 取り込み先は entrypoint.sh の実行時取り込みと同じ 2 か所:
#   1. JDK 同梱 cacerts        … ビルド時は root なので直接書き込める
#                                 (実行時は UID 185 のため /tmp へコピーして追加する)
#   2. jboss-truststore.p12    … cli/elytron-truststore.cli の key-store=appTrustStore
#                                 が参照するファイルそのもの
# secret を渡さなかった場合は /run/secrets/cacert.crt が存在しないため何もしない。
# その場合は従来どおり entrypoint.sh が起動時に ${PKI_TRUST_DIR} から取り込む
# (= このステップの追加で既存のビルド手順は一切壊れない)。
#
# --mount=type=secret はビルド中だけ tmpfs にマウントされ、イメージのレイヤーにも
# ビルドキャッシュにも残らない。
ARG CACERT_ALIAS=cacert
ARG JVM_TRUSTSTORE_PASSWORD=changeit
ARG JBOSS_TRUSTSTORE_PASSWORD=changeit
RUN --mount=type=secret,id=cacert,target=/run/secrets/cacert.crt \
    set -eu; \
    if [ ! -s /run/secrets/cacert.crt ]; then \
      echo "[build][cacert] build secret 'cacert' が渡されていないためビルド時取り込みをスキップします"; \
      echo "[build][cacert] (実行時に entrypoint.sh が \${PKI_TRUST_DIR} から取り込みます)"; \
    else \
      JDK_CACERTS=""; \
      for c in "${JAVA_HOME:-}/lib/security/cacerts" /etc/pki/java/cacerts; do \
        if [ -f "$c" ]; then JDK_CACERTS="$c"; break; fi; \
      done; \
      if [ -z "$JDK_CACERTS" ]; then \
        echo "[build][cacert] ERROR: JDK 同梱の cacerts が見つかりません"; exit 1; \
      fi; \
      keytool -importcert -noprompt -trustcacerts \
        -alias "${CACERT_ALIAS}" -file /run/secrets/cacert.crt \
        -keystore "$JDK_CACERTS" -storepass "${JVM_TRUSTSTORE_PASSWORD}"; \
      keytool -importcert -noprompt -trustcacerts \
        -alias "${CACERT_ALIAS}" -file /run/secrets/cacert.crt \
        -keystore "${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12" \
        -storetype PKCS12 -storepass "${JBOSS_TRUSTSTORE_PASSWORD}"; \
      chown 185:0 "${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12"; \
      chmod 0640  "${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12"; \
      mkdir -p /opt/pki; \
      { echo "imported-at : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"; \
        echo "alias       : ${CACERT_ALIAS}"; \
        echo "source      : build secret id=cacert (ビルド時取り込み)"; \
        echo "jdk store   : $JDK_CACERTS"; \
        echo "jboss store : ${JBOSS_HOME}/standalone/configuration/jboss-truststore.p12"; \
        keytool -printcert -file /run/secrets/cacert.crt 2>/dev/null \
          | grep -aE 'Owner|Issuer|SHA256|SHA-256|所有者|発行者|フィンガプリント' \
          | sed 's/^[[:space:]]*/cert        : /' || true; \
      } > /opt/pki/build-import.txt; \
      chmod 0644 /opt/pki/build-import.txt; \
      echo "[build][cacert] cacert.crt を JDK cacerts と jboss-truststore.p12 へ取り込みました"; \
      cat /opt/pki/build-import.txt; \
    fi

# アプリケーション WAR を配備 (アプリコードは無改変。front/app/ に WAR を置く)
COPY --chown=185:0 front/app/ ${JBOSS_HOME}/standalone/deployments/

# TLS 検証用サーブレット (コンテキストルート /tls-probe → /tls-probe/check)
COPY --from=probebuild --chown=185:0 /probe/target/tls-probe.war ${JBOSS_HOME}/standalone/deployments/

# Entrypoint
COPY --chown=185:0 front/entrypoint.sh /opt/bin/entrypoint.sh
RUN chmod 0755 /opt/bin/entrypoint.sh

USER 185
EXPOSE 8080
ENTRYPOINT ["/opt/bin/entrypoint.sh"]
