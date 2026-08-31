FROM mysql:8.0

COPY --chmod=0644 \
  config/mysql/00-create-databases.sql \
  /docker-entrypoint-initdb.d/00-create-databases.sql
