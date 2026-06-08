#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

COMPOSE_CMD="${COMPOSE_CMD:-podman compose}"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi
: "${TRANSPORT_TARGET:=k3s}"

ISOLATED=false
for _arg in "$@"; do [[ "$_arg" == "--isolated" ]] && ISOLATED=true && break; done
unset _arg

compose_down() {
  # shellcheck disable=SC2086
  if $ISOLATED; then
    # Remove named volumes (kube-config, k3s-data) scoped to this project run.
    # The external e2e-bin volume is NOT removed (shared binary cache).
    ${COMPOSE_CMD} $* --env-file .env down --remove-orphans --volumes
  else
    ${COMPOSE_CMD} $* --env-file .env down --remove-orphans
  fi
}

if $ISOLATED; then
  compose_down -f "${PWD}/docker-compose.yml" -f "${PWD}/docker-compose.isolated.yml"
  compose_down -f "${PWD}/docker-compose.gke.yml" -f "${PWD}/docker-compose.isolated.yml"
else
  compose_down -f "${PWD}/docker-compose.yml"
  compose_down -f "${PWD}/docker-compose.gke.yml"
fi

pid_dir="${ROOT_DIR}/.runtime"
for name in maestro-http maestro-grpc; do
  if [[ -f "${pid_dir}/${name}.pid" ]]; then
    pid="$(cat "${pid_dir}/${name}.pid")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" || true
    fi
    rm -f "${pid_dir}/${name}.pid"
  fi
done

echo "Teardown complete."
