ARG IS_VERSION=7.2.0
ARG FS_ACCELERATOR_VERSION=4.0.0
ARG MYSQL_CONNECTOR_VERSION=8.0.33
ARG NOTIFICATION_HANDLER_VERSION=2.1.3

FROM alpine:3.20 AS accelerator
ARG FS_ACCELERATOR_VERSION
RUN apk add --no-cache unzip
COPY dist/wso2-fsiam-accelerator-${FS_ACCELERATOR_VERSION}.zip /tmp/accelerator.zip
RUN mkdir -p /out && unzip -q /tmp/accelerator.zip -d /out

FROM wso2/wso2is:${IS_VERSION} AS merged
ARG IS_VERSION
ARG FS_ACCELERATOR_VERSION
ARG MYSQL_CONNECTOR_VERSION
ARG NOTIFICATION_HANDLER_VERSION

ENV WSO2_SERVER_HOME=/home/wso2carbon/wso2is-${IS_VERSION}

USER root

COPY --from=accelerator \
  /out/wso2-fsiam-accelerator-${FS_ACCELERATOR_VERSION} \
  ${WSO2_SERVER_HOME}/wso2-fsiam-accelerator-${FS_ACCELERATOR_VERSION}

COPY dist/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar \
  ${WSO2_SERVER_HOME}/repository/components/lib/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar

COPY dist/wso2is.notification.event.handlers-${NOTIFICATION_HANDLER_VERSION}.jar \
  ${WSO2_SERVER_HOME}/repository/components/dropins/wso2is.notification.event.handlers-${NOTIFICATION_HANDLER_VERSION}.jar

COPY .state/certs/wso2is.p12 \
  ${WSO2_SERVER_HOME}/repository/resources/security/wso2is.p12

COPY .state/certs/client-truststore.p12 \
  ${WSO2_SERVER_HOME}/repository/resources/security/client-truststore.p12

RUN chown -R wso2carbon:wso2 \
  ${WSO2_SERVER_HOME}/wso2-fsiam-accelerator-${FS_ACCELERATOR_VERSION} \
  ${WSO2_SERVER_HOME}/repository/components/lib \
  ${WSO2_SERVER_HOME}/repository/components/dropins \
  ${WSO2_SERVER_HOME}/repository/resources/security

USER wso2carbon

# WSO2's merge.sh derives product home from its current working directory.
RUN set -eux; \
  cd "${WSO2_SERVER_HOME}/wso2-fsiam-accelerator-${FS_ACCELERATOR_VERSION}/bin"; \
  bash ./merge.sh; \
  test -f "${WSO2_SERVER_HOME}/repository/conf/deployment.toml"; \
  cp "${WSO2_SERVER_HOME}/repository/conf/deployment.toml" /tmp/accelerator-deployment.toml

FROM python:3.12-alpine AS configmerge
RUN pip install --no-cache-dir tomlkit==0.13.2
COPY --from=merged /tmp/accelerator-deployment.toml /work/base.toml
COPY config/is/deployment.toml /work/overlay.toml
COPY tools/merge-toml.py /work/merge-toml.py
RUN python /work/merge-toml.py /work/base.toml /work/overlay.toml /work/deployment.toml

FROM merged
ARG IS_VERSION
ENV WSO2_SERVER_HOME=/home/wso2carbon/wso2is-${IS_VERSION}

USER root
COPY --from=configmerge /work/deployment.toml \
  ${WSO2_SERVER_HOME}/repository/conf/deployment.toml

# Replace the accelerator 4.0.0 identity extension with the compatibility
# build used by this demo. This contains the null-SSA DCR update fix required
# by WSO2 IS 7.2.
COPY dist/fs-is-accelerator-libs/org.wso2.financial.services.accelerator.identity.extensions-4.0.0.jar \
  ${WSO2_SERVER_HOME}/repository/components/dropins/org.wso2.financial.services.accelerator.identity.extensions-4.0.0.jar
RUN chown wso2carbon:wso2 \
  ${WSO2_SERVER_HOME}/repository/conf/deployment.toml
USER wso2carbon
