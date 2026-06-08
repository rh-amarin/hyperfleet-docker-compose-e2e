#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${PROJECTS:=$(dirname "$ROOT_DIR")}"
E2E_REPO="${E2E_REPO:-${PROJECTS}/hyperfleet-e2e/ue2e/main}"
NAMESPACE="${NAMESPACE:-hyperfleet-e2e-compose}"
ADAPTER_CONFIGS_DIR="${ROOT_DIR}/configs/adapters"
SRC_DIR="${E2E_REPO}/testdata/adapter-configs"

TIER0_CLUSTER_ADAPTERS=(cl-namespace cl-job cl-deployment cl-maestro)
TIER0_NODEPOOL_ADAPTERS=(np-configmap)

patch_adapter_config() {
  local file="$1"
  local api_url="$2"
  local topic="$3"
  local subscription="$4"
  local maestro_http="${5:-}"
  local maestro_grpc="${6:-}"

  sed -i.bak \
    -e "s|base_url: CHANGE_ME|base_url: ${api_url}|g" \
    -e "s|subscription_id: CHANGE_ME|subscription_id: ${subscription}|g" \
    -e "s|topic: CHANGE_ME|topic: ${topic}|g" \
    "$file"

  if [[ -n "$maestro_http" ]]; then
    sed -i.bak \
      -e "s|http://maestro.maestro.svc.cluster.local:8000|${maestro_http}|g" \
      -e "s|maestro-grpc.maestro.svc.cluster.local:8090|${maestro_grpc}|g" \
      "$file"
  fi

  if grep -q "kubernetes:" "$file"; then
    if ! grep -q "kube_config_path" "$file"; then
      sed -i.bak '/api_version:/a\
    kube_config_path: /kube/config' "$file"
    else
      sed -i.bak 's|kube_config_path:.*|kube_config_path: /kube/config|g' "$file"
    fi
  fi

  rm -f "${file}.bak"
}

write_broker_config() {
  local dir="$1"
  local queue="$2"
  local exchange="$3"

  cat > "${dir}/broker.yaml" <<EOF
broker:
  type: rabbitmq
  rabbitmq:
    url: amqp://guest:guest@rabbitmq:5672/
    queue: ${queue}
    exchange: ${exchange}
    routing_key: "#"
    exchange_type: topic

subscriber:
  parallelism: 1
EOF
}

main() {
  if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: E2E adapter configs not found at ${SRC_DIR}" >&2
    echo "Set E2E_REPO to the hyperfleet-e2e checkout (ue2e/main worktree)." >&2
    exit 1
  fi

  rm -rf "${ADAPTER_CONFIGS_DIR}"
  mkdir -p "${ADAPTER_CONFIGS_DIR}"

  for adapter in "${TIER0_CLUSTER_ADAPTERS[@]}"; do
    dest="${ADAPTER_CONFIGS_DIR}/${adapter}"
    mkdir -p "$dest"
    cp "${SRC_DIR}/${adapter}/adapter-config.yaml" "${dest}/adapter-config.yaml"
    cp "${SRC_DIR}/${adapter}/adapter-task-config.yaml" "${dest}/adapter-task-config.yaml"
    if [[ -f "${SRC_DIR}/${adapter}/adapter-task-resource-manifestwork.yaml" ]]; then
      cp "${SRC_DIR}/${adapter}/adapter-task-resource-manifestwork.yaml" "${dest}/manifestwork.yaml"
    fi
    if [[ -f "${SRC_DIR}/${adapter}/adapter-task-resource-job.yaml" ]]; then
      cp "${SRC_DIR}/${adapter}/adapter-task-resource-job.yaml" "${dest}/job.yaml"
    fi
    if [[ -f "${SRC_DIR}/${adapter}/adapter-task-resource-deployment.yaml" ]]; then
      cp "${SRC_DIR}/${adapter}/adapter-task-resource-deployment.yaml" "${dest}/deployment.yaml"
    fi

    topic="${NAMESPACE}-clusters"
    subscription="${NAMESPACE}-clusters-${adapter}"
    patch_adapter_config \
      "${dest}/adapter-config.yaml" \
      "http://hyperfleet-api:8000" \
      "${topic}" \
      "${subscription}" \
      "http://${MAESTRO_HOST_TARGET:-host.containers.internal}:${MAESTRO_HTTP_PORT:-8100}" \
      "${MAESTRO_HOST_TARGET:-host.containers.internal}:${MAESTRO_GRPC_PORT:-8090}"
    write_broker_config "$dest" "$subscription" "$topic"
  done

  for adapter in "${TIER0_NODEPOOL_ADAPTERS[@]}"; do
    dest="${ADAPTER_CONFIGS_DIR}/${adapter}"
    mkdir -p "$dest"
    cp "${SRC_DIR}/${adapter}/adapter-config.yaml" "${dest}/adapter-config.yaml"
    cp "${SRC_DIR}/${adapter}/adapter-task-config.yaml" "${dest}/adapter-task-config.yaml"
    if [[ -f "${SRC_DIR}/${adapter}/adapter-task-resource-configmap.yaml" ]]; then
      cp "${SRC_DIR}/${adapter}/adapter-task-resource-configmap.yaml" "${dest}/configmap.yaml"
    fi

    topic="${NAMESPACE}-nodepools"
    subscription="${NAMESPACE}-nodepools-${adapter}"
    patch_adapter_config \
      "${dest}/adapter-config.yaml" \
      "http://hyperfleet-api:8000" \
      "${topic}" \
      "${subscription}"
    write_broker_config "$dest" "$subscription" "$topic"
  done

  echo "Prepared adapter configs in ${ADAPTER_CONFIGS_DIR}"
}

main "$@"
