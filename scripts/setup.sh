#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# PROJECTS is the parent directory that contains all HyperFleet repos side-by-side.
# Override via env var; defaults to the directory containing this repo.
: "${PROJECTS:=$(dirname "$ROOT_DIR")}"
: "${INFRA_DIR:=${PROJECTS}/hyperfleet-infra}"
: "${E2E_REPO:=${PROJECTS}/hyperfleet-e2e}"
# Export so docker compose picks them up for volume bind mounts.
export INFRA_DIR E2E_REPO
: "${API_IMAGE:=hyperfleet-api:local}"
: "${SENTINEL_IMAGE:=hyperfleet-sentinel:local}"
: "${ADAPTER_IMAGE:=hyperfleet-adapter:local}"
export API_IMAGE SENTINEL_IMAGE ADAPTER_IMAGE
: "${TRANSPORT_TARGET:=k3s}"
: "${MAESTRO_HTTP_PORT:=8100}"
: "${MAESTRO_GRPC_PORT:=8090}"
: "${MAESTRO_CONSUMER:=cluster1}"

log() { printf '[setup] %s\n' "$*"; }

# Detect container runtime and compose command (podman preferred, docker fallback).
detect_runtime() {
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
    COMPOSE_CMD="${COMPOSE_CMD:-podman compose}"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
    COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"
  else
    echo "ERROR: neither podman nor docker found in PATH" >&2
    exit 1
  fi
}
detect_runtime
ISOLATED=false

# Parse --isolated early so compose flags are available in all functions.
for _arg in "$@"; do [[ "$_arg" == "--isolated" ]] && ISOLATED=true && break; done
unset _arg

# Returns "-f base [-f isolated]" flags for compose commands.
compose_flags() {
  local base
  if [[ "${TRANSPORT_TARGET}" == "k3s" ]]; then
    base="${ROOT_DIR}/docker-compose.yml"
  else
    base="${ROOT_DIR}/docker-compose.gke.yml"
  fi
  if $ISOLATED; then
    echo "-f ${base} -f ${ROOT_DIR}/docker-compose.isolated.yml"
  else
    echo "-f ${base}"
  fi
}

# Cached compose flags (set after TRANSPORT_TARGET is finalised in main).
COMPOSE_FLAGS=""

require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: required command not found: $cmd" >&2
      exit 1
    fi
  done
}

_build_image() {
  local tag="$1"
  local context="$2"
  local dockerfile="${context}/Dockerfile"
  local -a bargs=()
  [[ -n "${GOPROXY:-}" ]] && bargs+=(--build-arg "GOPROXY=${GOPROXY}")

  # If GOPROXY is set and the Dockerfile doesn't already declare ARG GOPROXY,
  # inject it before the first "COPY go.mod" line via a temp file so the source
  # repo is never modified.
  if [[ ${#bargs[@]} -gt 0 ]] && ! grep -q "^ARG GOPROXY" "$dockerfile"; then
    local tmp
    tmp="$(mktemp)"
    awk '/^COPY[[:space:]].*go\.mod/{print "ARG GOPROXY"} {print}' "$dockerfile" > "$tmp"
    ${CONTAINER_CMD} build "${bargs[@]}" -f "$tmp" -t "$tag" "$context"
    rm -f "$tmp"
  else
    ${CONTAINER_CMD} build "${bargs[@]}" -t "$tag" "$context"
  fi
}

build_images() {
  log "Building local container images..."
  _build_image "${API_IMAGE:-hyperfleet-api:local}"           "${PROJECTS}/hyperfleet-api"
  _build_image "${SENTINEL_IMAGE:-hyperfleet-sentinel:local}" "${PROJECTS}/hyperfleet-sentinel"
  _build_image "${ADAPTER_IMAGE:-hyperfleet-adapter:local}"   "${PROJECTS}/hyperfleet-adapter"
}

prepare_maestro_chart() {
  log "Updating Maestro Helm chart dependencies"
  helm dependency update "${INFRA_DIR}/helm/maestro"
}

prepare_configs() {
  log "Preparing adapter configs from ${E2E_REPO}"
  # In isolated mode the maestro server is a compose service called 'maestro-server'.
  # Override any stale MAESTRO_HOST_TARGET from .env.
  local maestro_host="${MAESTRO_HOST_TARGET:-}"
  if $ISOLATED && [[ "$maestro_host" != "maestro-server" ]]; then
    maestro_host="maestro-server"
  fi
  : "${maestro_host:=host.containers.internal}"
  MAESTRO_HTTP_PORT="$MAESTRO_HTTP_PORT" MAESTRO_GRPC_PORT="$MAESTRO_GRPC_PORT" \
    MAESTRO_HOST_TARGET="$maestro_host" \
    E2E_REPO="$E2E_REPO" NAMESPACE="${NAMESPACE:-hyperfleet-e2e-compose}" \
    "${ROOT_DIR}/scripts/prepare-adapter-configs.sh"
}

prepare_k3s() {
  require_cmd helm
  prepare_maestro_chart
  mkdir -p "${ROOT_DIR}/configs/kube"
  # Podman creates directories when binding missing single files; remove before bootstrap.
  rm -rf "${ROOT_DIR}/configs/kube/config" "${ROOT_DIR}/configs/kube/config-host" "${ROOT_DIR}/configs/kube/admin.yaml"

  # k3s node names are container IDs; reusing the data volume leaves ghost NotReady nodes.
  if [[ "${RESET_K3S_DATA:-true}" == "true" ]]; then
    local vol="${COMPOSE_PROJECT_NAME:-hyperfleet-e2e}_k3s-data"
    if ${CONTAINER_CMD} volume inspect "$vol" >/dev/null 2>&1; then
      log "Removing stale k3s data volume (${vol})"
      # shellcheck disable=SC2086
      ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env down 2>/dev/null || true
      ${CONTAINER_CMD} volume rm "$vol" || true
    fi
  fi
}

prepare_gke() {
  require_cmd kubectl curl
  : "${KUBE_CONTEXT:=gke_hcm-hyperfleet_europe-southwest1-a_hyperfleet-dev-amarin-eu1}"
  log "Selecting Kubernetes context ${KUBE_CONTEXT}"
  kubectl config use-context "$KUBE_CONTEXT"
  KUBE_CONTEXT="$KUBE_CONTEXT" "${ROOT_DIR}/scripts/prepare-kubeconfig.sh"
  MAESTRO_HOST_TARGET="${MAESTRO_HOST_TARGET:-host.containers.internal}"
}

start_maestro_port_forward() {
  local pid_dir="${ROOT_DIR}/.runtime"
  mkdir -p "$pid_dir"

  if [[ -f "${pid_dir}/maestro-http.pid" ]] && kill -0 "$(cat "${pid_dir}/maestro-http.pid")" 2>/dev/null; then
    log "Maestro HTTP port-forward already running on ${MAESTRO_HTTP_PORT}"
  else
    log "Starting Maestro HTTP port-forward localhost:${MAESTRO_HTTP_PORT} -> maestro/maestro:8000"
    kubectl port-forward -n maestro svc/maestro "${MAESTRO_HTTP_PORT}:8000" \
      >"${pid_dir}/maestro-http.log" 2>&1 &
    echo $! >"${pid_dir}/maestro-http.pid"
  fi

  if [[ -f "${pid_dir}/maestro-grpc.pid" ]] && kill -0 "$(cat "${pid_dir}/maestro-grpc.pid")" 2>/dev/null; then
    log "Maestro gRPC port-forward already running on ${MAESTRO_GRPC_PORT}"
  else
    log "Starting Maestro gRPC port-forward localhost:${MAESTRO_GRPC_PORT} -> maestro/maestro-grpc:8090"
    kubectl port-forward -n maestro svc/maestro-grpc "${MAESTRO_GRPC_PORT}:8090" \
      >"${pid_dir}/maestro-grpc.log" 2>&1 &
    echo $! >"${pid_dir}/maestro-grpc.pid"
  fi

  for _ in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${MAESTRO_HTTP_PORT}/api/maestro/v1/consumers" >/dev/null 2>&1; then
      log "Maestro HTTP API is reachable"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Maestro HTTP API not reachable on port ${MAESTRO_HTTP_PORT}" >&2
  exit 1
}

ensure_maestro_consumer() {
  log "Ensuring Maestro consumer '${MAESTRO_CONSUMER}' exists"
  if $ISOLATED; then
    # Reach maestro-server from inside the compose network via k3s-maestro-proxy (alpine/k8s has curl).
    # shellcheck disable=SC2086
    ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env exec -T k3s-maestro-proxy sh -c \
      "curl -sf -X POST -H 'Content-Type: application/json' \
        http://maestro-server:8100/api/maestro/v1/consumers \
        -d '{\"name\": \"${MAESTRO_CONSUMER}\"}' >/dev/null || \
       curl -sf http://maestro-server:8100/api/maestro/v1/consumers | grep -q '\"${MAESTRO_CONSUMER}\"'"
    return 0
  fi
  if curl -sf "http://127.0.0.1:${MAESTRO_HTTP_PORT}/api/maestro/v1/consumers" | grep -q "\"name\":\"${MAESTRO_CONSUMER}\""; then
    log "Consumer '${MAESTRO_CONSUMER}' already registered"
    return 0
  fi
  curl -sf -X POST \
    -H "Content-Type: application/json" \
    "http://127.0.0.1:${MAESTRO_HTTP_PORT}/api/maestro/v1/consumers" \
    -d "{\"name\": \"${MAESTRO_CONSUMER}\"}" >/dev/null
  log "Created Maestro consumer '${MAESTRO_CONSUMER}'"
}

start_compose() {
  log "Starting docker compose stack (transport=${TRANSPORT_TARGET}, isolated=${ISOLATED})"
  # shellcheck disable=SC2086
  ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env up -d
}

wait_for_stack() {
  log "Waiting for core services to become healthy"
  # shellcheck disable=SC2086
  ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env ps
  if $ISOLATED; then
    # No host ports in isolated mode — probe from inside k3s-maestro-proxy (alpine/k8s has wget).
    for _ in $(seq 1 90); do
      if ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env exec -T k3s-maestro-proxy \
          curl -sf "http://hyperfleet-api:8000/api/hyperfleet/v1/openapi" >/dev/null 2>&1; then
        log "HyperFleet API is ready (isolated)"
        return 0
      fi
      sleep 2
    done
    echo "ERROR: HyperFleet API did not become ready in time" >&2
    # shellcheck disable=SC2086
    ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env ps
    exit 1
  fi
  local api_port="${API_HOST_PORT:-18000}"
  for _ in $(seq 1 90); do
    if curl -sf "http://127.0.0.1:${api_port}/api/hyperfleet/v1/openapi" >/dev/null 2>&1; then
      log "HyperFleet API is ready on port ${api_port}"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: HyperFleet API did not become ready in time" >&2
  # shellcheck disable=SC2086
  ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env ps
  exit 1
}

wait_for_k3s_bootstrap() {
  log "Waiting for k3s-bootstrap to complete"
  if $ISOLATED; then
    # Kubeconfigs live in the kube-config named volume (mounted at /output in k3s).
    # No host path to check — poll via exec into the running k3s container.
    for _ in $(seq 1 120); do
      # shellcheck disable=SC2086
      if ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env exec -T k3s \
          test -f /output/config -a -f /output/config-host -a -f /output/admin.yaml 2>/dev/null; then
        log "k3s bootstrap artifacts present (isolated)"
        return 0
      fi
      sleep 2
    done
    echo "ERROR: k3s bootstrap did not complete" >&2
    # shellcheck disable=SC2086
    ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env logs k3s-bootstrap
    exit 1
  fi
  for _ in $(seq 1 120); do
    if [[ -f "${ROOT_DIR}/configs/kube/config" && -f "${ROOT_DIR}/configs/kube/config-host" && -f "${ROOT_DIR}/configs/kube/admin.yaml" ]]; then
      log "k3s bootstrap artifacts present"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: k3s bootstrap did not complete" >&2
  # shellcheck disable=SC2086
  ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env logs k3s-bootstrap
  exit 1
}

main() {
  require_cmd "${CONTAINER_CMD}" curl

  # COMPOSE_FLAGS must be set after TRANSPORT_TARGET (and optionally ISOLATED) are known.
  # shellcheck disable=SC2034
  COMPOSE_FLAGS="$(compose_flags)"

  if [[ "${TRANSPORT_TARGET}" == "k3s" ]]; then
    prepare_k3s
    prepare_configs
    if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
      build_images
    fi
    start_compose
    wait_for_k3s_bootstrap
    if $ISOLATED; then
      # maestro-server is a compose service — check it via k3s-maestro-proxy (alpine/k8s has curl).
      log "Waiting for Maestro server to become reachable (isolated)"
      _maestro_ready=false
      for _ in $(seq 1 60); do
        # shellcheck disable=SC2086
        if ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env exec -T k3s-maestro-proxy \
            curl -sf "http://maestro-server:8100/api/maestro/v1/consumers" >/dev/null 2>&1; then
          _maestro_ready=true
          break
        fi
        sleep 5
      done
      if ! $_maestro_ready; then
        echo "ERROR: maestro-server not reachable (isolated)" >&2
        # shellcheck disable=SC2086
        ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env logs maestro-server
        exit 1
      fi
      log "Maestro HTTP API is ready (isolated)"
    else
      log "Waiting for Maestro HTTP API on port ${MAESTRO_HTTP_PORT}"
      for _ in $(seq 1 60); do
        if curl -sf "http://127.0.0.1:${MAESTRO_HTTP_PORT}/api/maestro/v1/consumers" >/dev/null 2>&1; then
          log "Maestro HTTP API is ready"
          break
        fi
        sleep 5
      done
      if ! curl -sf "http://127.0.0.1:${MAESTRO_HTTP_PORT}/api/maestro/v1/consumers" >/dev/null 2>&1; then
        echo "ERROR: maestro-server not reachable on port ${MAESTRO_HTTP_PORT}" >&2
        exit 1
      fi
    fi
    ensure_maestro_consumer
    wait_for_stack
    if $ISOLATED; then
      log "Stack is up (k3s, isolated). Run: ./scripts/run-tier0.sh --isolated"
    else
      log "Stack is up (k3s). API: http://localhost:${API_HOST_PORT:-18000}  Maestro: http://localhost:${MAESTRO_HTTP_PORT}"
    fi
  else
    prepare_gke
    prepare_configs
    if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
      build_images
    fi
    start_maestro_port_forward
    ensure_maestro_consumer
    start_compose
    wait_for_stack
    log "Stack is up (gke). API: http://localhost:${API_HOST_PORT:-18000}  Maestro: http://localhost:${MAESTRO_HTTP_PORT}"
  fi
}

main "$@"
