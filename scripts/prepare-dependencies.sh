#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
mkdir -p dist
MYSQL_VER=${MYSQL_CONNECTOR_VERSION:-8.0.33}
MYSQL_JAR="dist/mysql-connector-j-${MYSQL_VER}.jar"
HANDLER_VER=${NOTIFICATION_HANDLER_VERSION:-2.1.3}
HANDLER_JAR="dist/wso2is.notification.event.handlers-${HANDLER_VER}.jar"
download(){ local url=$1 out=$2; [[ -s "$out" ]] && return; log "Downloading $(basename "$out")"; curl -fL --retry 4 --retry-delay 2 "$url" -o "$out"; }
download "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_VER}/mysql-connector-j-${MYSQL_VER}.jar" "$MYSQL_JAR"
download "https://maven.wso2.org/nexus/content/repositories/releases/org/wso2/km/ext/wso2is/wso2is.notification.event.handlers/${HANDLER_VER}/wso2is.notification.event.handlers-${HANDLER_VER}.jar" "$HANDLER_JAR"
# Dockerfiles use the documented/default pinned names; prevent accidental version drift.
[[ "$MYSQL_VER" == "8.0.33" ]] || fatal "This repository currently pins Dockerfile copy path to MySQL Connector/J 8.0.33; update Dockerfiles deliberately before changing MYSQL_CONNECTOR_VERSION."
[[ "$HANDLER_VER" == "2.1.3" ]] || fatal "APIM 4.7 docs explicitly call for notification handler 2.1.3; update deliberately before changing NOTIFICATION_HANDLER_VERSION."
