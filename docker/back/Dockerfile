# =============================================================================
# バックコンテナ用 Dockerfile (フロントとの差分: WAR / entrypoint / EXPOSE 8180)
# ビルドコンテキストは docker/ 直下 (docker build -f back/Dockerfile .)
# =============================================================================
ARG EAP_BASE_IMAGE=<EAP_BASE_IMAGE>
ARG ADOT_JAVA_AGENT_VERSION=v2.11.5
ARG MYSQL_CONNECTOR_VERSION=8.4.0

FROM public.ecr.aws/aws-observability/adot-autoinstrumentation-java:${ADOT_JAVA_AGENT_VERSION} AS adot

FROM ${EAP_BASE_IMAGE}
ARG MYSQL_CONNECTOR_VERSION
ENV JBOSS_HOME=/opt/server
USER root

COPY --from=adot --chown=185:0 /javaagent.jar /opt/adot/aws-opentelemetry-agent.jar

RUN curl -fsSL -o /tmp/mysql-connector-j.jar \
      "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_CONNECTOR_VERSION}/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar"

COPY cli/mysql-xa-datasource.cli /tmp/config.cli
RUN "${JBOSS_HOME}/bin/jboss-cli.sh" --file=/tmp/config.cli \
 && rm -f /tmp/config.cli /tmp/mysql-connector-j.jar \
 && rm -rf "${JBOSS_HOME}/standalone/configuration/standalone_xml_history" \
 && chown -R 185:0 "${JBOSS_HOME}/standalone" "${JBOSS_HOME}/modules" \
 && chmod -R g=u "${JBOSS_HOME}/standalone"

COPY --chown=185:0 back/app/ ${JBOSS_HOME}/standalone/deployments/

COPY --chown=185:0 back/entrypoint.sh /opt/bin/entrypoint.sh
RUN chmod 0755 /opt/bin/entrypoint.sh

USER 185
# 起動時 port-offset=100 のため HTTP は 8180
EXPOSE 8180
ENTRYPOINT ["/opt/bin/entrypoint.sh"]
