#!/usr/bin/env sh
# Forwards the in-cluster Mosquitto MQTT broker to the compose network so that
# the maestro-server compose service can reach it. The maestro-server and agent
# communicate through this broker; the agent stays inside k3s and connects directly
# via Kubernetes DNS (maestro-mqtt.maestro.svc.cluster.local:1883).
set -eu

export KUBECONFIG="${KUBECONFIG:-/kube/admin.yaml}"
MQTT_PORT="${MQTT_PORT:-1883}"
MAESTRO_NS="${MAESTRO_NS:-maestro}"

printf '[k3s-maestro-proxy] forwarding maestro MQTT :%s\n' "$MQTT_PORT"

exec kubectl port-forward -n "${MAESTRO_NS}" "svc/maestro-mqtt" "${MQTT_PORT}:1883" --address 0.0.0.0
