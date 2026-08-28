#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
APIM_IMG="wso2-ob-demo-apim:${APIM_VERSION:-4.6.0}-fs${FS_ACCELERATOR_VERSION:-4.0.0}"
IS_IMG="wso2-ob-demo-is:${IS_VERSION:-7.2.0}-fs${FS_ACCELERATOR_VERSION:-4.0.0}"
mysqlq(){ docker compose exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD:-root}" "$@"; }
count_tables(){ mysqlq -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1';"; }
apply_candidates(){ local image=$1 db=$2; shift 2; local marker; marker=$(count_tables "$db"); if (( marker > 5 )); then log "$db already initialized ($marker tables)"; return; fi; for candidate in "$@"; do log "Applying $candidate -> $db (when present)"; docker run --rm --entrypoint sh "$image" -c "if [ -f '$candidate' ]; then cat '$candidate'; fi" | mysqlq "$db"; done; }
log "Initializing WSO2 schemas from the exact built images"

# Guard against MySQL 8 utf8mb4 defaults causing WSO2 compound indexes to
# exceed InnoDB's 3072-byte index-key limit. These demo databases must be
# created as latin1/latin1_bin before product schemas are loaded.
for db in fs_identitydb fs_userdb fs_iskm_configdb fs_consentdb fs_apimgtdb fs_am_configdb fs_am_userdb; do
  db_charset="$(mysqlq -Nse "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}'" || true)"
  db_collation="$(mysqlq -Nse "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}'" || true)"

  [[ "$db_charset" == "latin1" ]] || fatal     "$db uses charset '$db_charset'; expected latin1. Recreate the MySQL volume after applying the database patch."

  [[ "$db_collation" == "latin1_bin" ]] || fatal     "$db uses collation '$db_collation'; expected latin1_bin. Recreate the MySQL volume after applying the database patch."
done

ISH="/home/wso2carbon/wso2is-${IS_VERSION:-7.2.0}"
AMH="/home/wso2carbon/wso2am-${APIM_VERSION:-4.6.0}"
apply_candidates "$IS_IMG" fs_identitydb "$ISH/dbscripts/identity/mysql.sql" "$ISH/dbscripts/consent/mysql.sql"
apply_candidates "$IS_IMG" fs_userdb "$ISH/dbscripts/mysql.sql"
apply_candidates "$IS_IMG" fs_iskm_configdb "$ISH/dbscripts/mysql.sql"
apply_candidates "$IS_IMG" fs_consentdb "$ISH/dbscripts/financial-services/consent/mysql.sql" "$ISH/dbscripts/financial-services/event-notifications/mysql.sql"
apply_candidates "$APIM_IMG" fs_apimgtdb "$AMH/dbscripts/apimgt/mysql.sql"
apply_candidates "$APIM_IMG" fs_am_configdb "$AMH/dbscripts/mysql.sql"
apply_candidates "$APIM_IMG" fs_am_userdb "$AMH/dbscripts/mysql.sql"
# Accelerator prerequisite: extend service-provider metadata value where the table exists.
mysqlq fs_identitydb -e "ALTER TABLE SP_METADATA MODIFY VALUE VARCHAR(4096);" >/dev/null 2>&1 || true
# Fail if expected DBs are still empty: catches moved schema paths in the unsupported product combination.
for db in fs_identitydb fs_userdb fs_iskm_configdb fs_consentdb fs_apimgtdb fs_am_configdb fs_am_userdb; do n=$(count_tables "$db"); (( n > 0 )) || fatal "$db has zero tables after schema initialization. This is a compatibility/path gate; inspect the built image's dbscripts tree."; done
