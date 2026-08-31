ARG APIM_VERSION=4.6.0
ARG FS_APIM_MEDIATION_POLICIES_VERSION=1.0.0
ARG MYSQL_CONNECTOR_VERSION=8.0.33

FROM alpine:3.20 AS policies
ARG FS_APIM_MEDIATION_POLICIES_VERSION

RUN apk add --no-cache unzip

COPY dist/fs-apim-mediation-artifacts-${FS_APIM_MEDIATION_POLICIES_VERSION}.zip \
  /tmp/policies.zip

RUN set -eux; \
    mkdir -p /raw /normalized; \
    unzip -q /tmp/policies.zip -d /raw; \
    BASE="$(find /raw -type d -name policy-j2-files | head -n 1 | sed 's#/policy-j2-files$##')"; \
    test -n "${BASE}"; \
    test -d "${BASE}/lib"; \
    test -d "${BASE}/custom-sequences"; \
    test -d "${BASE}/policy-j2-files"; \
    mkdir -p /normalized/lib /normalized/custom-sequences /normalized/policy-j2-files; \
    cp -a "${BASE}/lib/." /normalized/lib/; \
    cp -a "${BASE}/custom-sequences/." /normalized/custom-sequences/; \
    cp -a "${BASE}/policy-j2-files/." /normalized/policy-j2-files/; \
    test "$(find /normalized/lib -type f | wc -l)" -gt 0; \
    test "$(find /normalized/custom-sequences -type f | wc -l)" -gt 0; \
    test "$(find /normalized/policy-j2-files -type f | wc -l)" -gt 0

FROM wso2/wso2am:${APIM_VERSION} AS prepared
ARG APIM_VERSION
ARG MYSQL_CONNECTOR_VERSION

ENV WSO2_SERVER_HOME=/home/wso2carbon/wso2am-${APIM_VERSION}

USER root

COPY dist/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar \
  ${WSO2_SERVER_HOME}/repository/components/lib/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar

COPY .state/certs/wso2apim.p12 \
  ${WSO2_SERVER_HOME}/repository/resources/security/wso2apim.p12

COPY .state/certs/wso2is.p12 /tmp/wso2is.p12

# WSO2 Financial Services Accelerator 4.0.0 APIM-side OSGi bundles.
# The demo installs the compatible FS common + Key Manager bundles only.
COPY dist/fs-apim-accelerator-libs/ \
  ${WSO2_SERVER_HOME}/repository/components/dropins/

# Replace APIM's installed WSO2 IS7 Key Manager 2.0.8 bundle in place.
# Keeping only one bundle avoids duplicate OSGi bundles with the same
# symbolic name/version in plugins and dropins.
RUN rm -f \
  ${WSO2_SERVER_HOME}/repository/components/dropins/wso2is7.key.manager*.jar \
  ${WSO2_SERVER_HOME}/repository/components/plugins/wso2is7.key.manager_2.0.8.jar

COPY --chown=wso2carbon:wso2 --chmod=0644 \
  dist/custom-apim-libs/wso2is7.key.manager_2.0.8.jar \
  ${WSO2_SERVER_HOME}/repository/components/plugins/wso2is7.key.manager_2.0.8.jar


COPY --from=policies /normalized/lib/ \
  ${WSO2_SERVER_HOME}/repository/components/lib/

COPY --from=policies /normalized/custom-sequences/ \
  ${WSO2_SERVER_HOME}/repository/deployment/server/synapse-configs/default/sequences/

COPY --from=policies /normalized/policy-j2-files/ \
  /opt/wso2-ob/policies/

RUN set -eux; \
    SECURITY="${WSO2_SERVER_HOME}/repository/resources/security"; \
    test -f "${SECURITY}/client-truststore.jks"; \
    APIM_ALIAS="$(keytool -list -v \
      -keystore "${SECURITY}/wso2apim.p12" \
      -storetype PKCS12 \
      -storepass wso2carbon 2>/dev/null \
      | awk -F': ' '/Alias name:/{print $2; exit}')"; \
    IS_ALIAS="$(keytool -list -v \
      -keystore /tmp/wso2is.p12 \
      -storetype PKCS12 \
      -storepass wso2carbon 2>/dev/null \
      | awk -F': ' '/Alias name:/{print $2; exit}')"; \
    test -n "${APIM_ALIAS}"; \
    test -n "${IS_ALIAS}"; \
    echo "APIM TLS alias: ${APIM_ALIAS}"; \
    echo "IS TLS alias: ${IS_ALIAS}"; \
    keytool -exportcert -rfc \
      -alias "${APIM_ALIAS}" \
      -keystore "${SECURITY}/wso2apim.p12" \
      -storetype PKCS12 \
      -storepass wso2carbon \
      -file /tmp/apim-tls.crt; \
    keytool -exportcert -rfc \
      -alias "${IS_ALIAS}" \
      -keystore /tmp/wso2is.p12 \
      -storetype PKCS12 \
      -storepass wso2carbon \
      -file /tmp/is-tls.crt; \
    keytool -delete -alias demo-apim-tls \
      -keystore "${SECURITY}/client-truststore.jks" \
      -storepass wso2carbon >/dev/null 2>&1 || true; \
    keytool -delete -alias demo-is-tls \
      -keystore "${SECURITY}/client-truststore.jks" \
      -storepass wso2carbon >/dev/null 2>&1 || true; \
    keytool -importcert -noprompt -trustcacerts \
      -alias demo-apim-tls \
      -file /tmp/apim-tls.crt \
      -keystore "${SECURITY}/client-truststore.jks" \
      -storepass wso2carbon; \
    keytool -importcert -noprompt -trustcacerts \
      -alias demo-is-tls \
      -file /tmp/is-tls.crt \
      -keystore "${SECURITY}/client-truststore.jks" \
      -storepass wso2carbon; \
    keytool -list \
      -keystore "${SECURITY}/client-truststore.jks" \
      -storepass wso2carbon \
      | grep -E 'demo-apim-tls|demo-is-tls'; \
    rm -f /tmp/wso2is.p12 /tmp/apim-tls.crt /tmp/is-tls.crt; \
    chown -R wso2carbon:wso2 \
      "${SECURITY}" \
      "${WSO2_SERVER_HOME}/repository/components/lib" \
      "${WSO2_SERVER_HOME}/repository/components/dropins" \
      "${WSO2_SERVER_HOME}/repository/deployment/server/synapse-configs/default/sequences" \
      /opt/wso2-ob

FROM python:3.12-alpine AS configmerge
ARG APIM_VERSION

RUN pip install --no-cache-dir tomlkit==0.13.2

COPY --from=prepared \
  /home/wso2carbon/wso2am-${APIM_VERSION}/repository/conf/deployment.toml \
  /work/base.toml

COPY config/apim/deployment.toml /work/overlay.toml

COPY tools/merge-toml.py /work/merge-toml.py

RUN python /work/merge-toml.py \
  /work/base.toml \
  /work/overlay.toml \
  /work/deployment.toml

FROM prepared
ARG APIM_VERSION

ENV WSO2_SERVER_HOME=/home/wso2carbon/wso2am-${APIM_VERSION}

USER root

COPY --from=configmerge /work/deployment.toml \
  ${WSO2_SERVER_HOME}/repository/conf/deployment.toml

COPY config/apim/financial-services.xml /home/wso2carbon/wso2am-4.6.0/repository/conf/financial-services.xml

RUN chown wso2carbon:wso2 \
  ${WSO2_SERVER_HOME}/repository/conf/deployment.toml

USER wso2carbon
