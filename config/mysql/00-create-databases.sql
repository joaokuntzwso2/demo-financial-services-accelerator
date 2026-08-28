-- WSO2 demo databases.
--
-- MySQL 8 defaults to utf8mb4, but several WSO2 Identity Server / API Manager
-- schema indexes are sized for latin1. Use a case-sensitive latin1 collation
-- for this local WSO2 demo to avoid MySQL ERROR 1071 (max key length 3072).
--
-- This is intentionally explicit per database so Docker/MySQL defaults cannot
-- silently change the schema characteristics.

CREATE DATABASE IF NOT EXISTS fs_identitydb
  CHARACTER SET latin1 COLLATE latin1_bin;

CREATE DATABASE IF NOT EXISTS fs_userdb
  CHARACTER SET latin1 COLLATE latin1_bin;

CREATE DATABASE IF NOT EXISTS fs_iskm_configdb
  CHARACTER SET latin1 COLLATE latin1_bin;

CREATE DATABASE IF NOT EXISTS fs_consentdb
  CHARACTER SET latin1 COLLATE latin1_bin;

CREATE DATABASE IF NOT EXISTS fs_apimgtdb
  CHARACTER SET latin1 COLLATE latin1_bin;

CREATE DATABASE IF NOT EXISTS fs_am_configdb
  CHARACTER SET latin1 COLLATE latin1_bin;

CREATE DATABASE IF NOT EXISTS fs_am_userdb
  CHARACTER SET latin1 COLLATE latin1_bin;

GRANT ALL PRIVILEGES ON fs_identitydb.* TO 'wso2'@'%';
GRANT ALL PRIVILEGES ON fs_userdb.* TO 'wso2'@'%';
GRANT ALL PRIVILEGES ON fs_iskm_configdb.* TO 'wso2'@'%';
GRANT ALL PRIVILEGES ON fs_consentdb.* TO 'wso2'@'%';
GRANT ALL PRIVILEGES ON fs_apimgtdb.* TO 'wso2'@'%';
GRANT ALL PRIVILEGES ON fs_am_configdb.* TO 'wso2'@'%';
GRANT ALL PRIVILEGES ON fs_am_userdb.* TO 'wso2'@'%';

FLUSH PRIVILEGES;
