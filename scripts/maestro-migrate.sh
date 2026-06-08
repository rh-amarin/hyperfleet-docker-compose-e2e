#!/bin/sh
# Database migration script for the maestro-migrate compose service.
# Writes the file-based secrets the maestro binary expects, then runs migration.
set -eu

mkdir -p /tmp/maestro/rds

printf '%s' "${DB_HOST}"     > /tmp/maestro/rds/db.host
printf '%s' "${DB_PORT}"     > /tmp/maestro/rds/db.port
printf '%s' "${DB_USER}"     > /tmp/maestro/rds/db.user
printf '%s' "${DB_PASSWORD}" > /tmp/maestro/rds/db.password
printf '%s' "${DB_NAME}"     > /tmp/maestro/rds/db.name

exec /usr/local/bin/maestro migration \
  --db-host-file=/tmp/maestro/rds/db.host \
  --db-port-file=/tmp/maestro/rds/db.port \
  --db-user-file=/tmp/maestro/rds/db.user \
  --db-password-file=/tmp/maestro/rds/db.password \
  --db-name-file=/tmp/maestro/rds/db.name \
  --db-sslmode=disable \
  --alsologtostderr \
  -v=2
