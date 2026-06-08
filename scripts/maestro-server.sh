#!/bin/sh
# Startup script for the maestro-server compose service.
# Writes the file-based secrets the maestro binary expects, then exec's the server.
set -eu

mkdir -p /tmp/maestro/rds /tmp/maestro/mqtt

printf '%s' "${DB_HOST}"     > /tmp/maestro/rds/db.host
printf '%s' "${DB_PORT}"     > /tmp/maestro/rds/db.port
printf '%s' "${DB_USER}"     > /tmp/maestro/rds/db.user
printf '%s' "${DB_PASSWORD}" > /tmp/maestro/rds/db.password
printf '%s' "${DB_NAME}"     > /tmp/maestro/rds/db.name

cat > /tmp/maestro/mqtt/config.yaml <<EOF
brokerHost: ${MQTT_HOST}:${MQTT_PORT}
topics:
  sourceEvents: sources/maestro/consumers/+/sourceevents
  agentEvents: sources/maestro/consumers/+/agentevents
EOF

exec /usr/local/bin/maestro server \
  --db-host-file=/tmp/maestro/rds/db.host \
  --db-port-file=/tmp/maestro/rds/db.port \
  --db-user-file=/tmp/maestro/rds/db.user \
  --db-password-file=/tmp/maestro/rds/db.password \
  --db-name-file=/tmp/maestro/rds/db.name \
  --db-sslmode=disable \
  --message-broker-type=mqtt \
  --message-broker-config-file=/tmp/maestro/mqtt/config.yaml \
  --enable-https=false \
  --server-hostname=0.0.0.0 \
  --http-server-bindport=8100 \
  --grpc-server-bindport=8090 \
  --health-check-server-bindport=8083 \
  --enable-health-check-https=false \
  --enable-metrics-https=false \
  --alsologtostderr \
  -v=2
