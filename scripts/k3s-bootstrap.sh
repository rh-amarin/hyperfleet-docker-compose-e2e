#!/usr/bin/env sh
set -eu

KUBE_DIR="${KUBE_DIR:-/kube}"
INFRA_DIR="${INFRA_DIR:-/infra}"
MAESTRO_NS="${MAESTRO_NS:-maestro}"
MAESTRO_CONSUMER="${MAESTRO_CONSUMER:-cluster1}"
K3S_HOST="${K3S_HOST:-k3s}"
K3S_API_HOST_PORT="${K3S_API_HOST_PORT:-16443}"
ADAPTER_SA_NAMESPACE="${ADAPTER_SA_NAMESPACE:-hyperfleet}"
ADAPTER_SA_NAME="${ADAPTER_SA_NAME:-hyperfleet-e2e-adapter}"
TOKEN_DURATION="${KUBE_TOKEN_DURATION:-8760h}"

log() { printf '[k3s-bootstrap] %s\n' "$*"; }

cleanup_stale_nodes() {
  log "Removing stale NotReady nodes (left over from prior k3s container IDs)"
  kubectl get nodes --no-headers 2>/dev/null | while read -r name status _; do
    if [ "$status" = "NotReady" ]; then
      kubectl delete node "$name" --ignore-not-found
    fi
  done
}

wait_for_k3s_kubeconfig() {
  local i=0
  while [ ! -f "${KUBE_DIR}/kubeconfig.yaml" ]; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
      log "ERROR: k3s kubeconfig not found at ${KUBE_DIR}/kubeconfig.yaml"
      exit 1
    fi
    sleep 2
  done
}

write_admin_kubeconfig() {
  # Admin config for bootstrap + maestro proxy (in-cluster TLS to k3s API).
  sed "s|127.0.0.1|${K3S_HOST}|g; s|localhost|${K3S_HOST}|g" \
    "${KUBE_DIR}/kubeconfig.yaml" >"${KUBE_DIR}/admin.yaml"
  chmod 644 "${KUBE_DIR}/admin.yaml"
  export KUBECONFIG="${KUBE_DIR}/admin.yaml"
}

write_kubeconfig_file() {
  local outfile="$1" server="$2"
  local cluster_name ca_data token
  cluster_name="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
  ca_data="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  token="$(kubectl create token "${ADAPTER_SA_NAME}" -n "${ADAPTER_SA_NAMESPACE}" --duration="${TOKEN_DURATION}")"

  cat >"${outfile}" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${ca_data}
    server: ${server}
  name: ${cluster_name}
contexts:
- context:
    cluster: ${cluster_name}
    user: hyperfleet-e2e-adapter
  name: ${cluster_name}
current-context: ${cluster_name}
users:
- name: hyperfleet-e2e-adapter
  user:
    token: ${token}
EOF
  chmod 644 "${outfile}"
}

write_adapter_kubeconfig() {
  write_kubeconfig_file "${KUBE_DIR}/config" "https://${K3S_HOST}:6443"
  log "Wrote adapter kubeconfig to ${KUBE_DIR}/config"

  write_kubeconfig_file "${KUBE_DIR}/config-host" "https://127.0.0.1:${K3S_API_HOST_PORT}"
  log "Wrote host kubeconfig to ${KUBE_DIR}/config-host"
}

install_maestro() {
  log "Installing Maestro agent + MQTT broker in namespace ${MAESTRO_NS}"
  log "(Maestro server and PostgreSQL run as compose services outside the cluster)"
  kubectl create namespace "${MAESTRO_NS}" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install "${MAESTRO_NS}-maestro" "${INFRA_DIR}/helm/maestro" \
    --namespace "${MAESTRO_NS}" \
    -f /manifests/maestro-values.yaml \
    --set agent.messageBroker.mqtt.host="maestro-mqtt.${MAESTRO_NS}" \
    --set agent.consumerName="${MAESTRO_CONSUMER}" \
    --wait --timeout 15m

  kubectl wait --for=condition=ready pod \
    -l "app.kubernetes.io/instance=${MAESTRO_NS}-maestro" \
    -n "${MAESTRO_NS}" --timeout=300s

  log "Maestro pods (agent + MQTT) are ready"
}

apply_adapter_rbac() {
  log "Applying adapter RBAC"
  kubectl apply -f /manifests/adapter-rbac.yaml
}

main() {
  wait_for_k3s_kubeconfig
  write_admin_kubeconfig
  cleanup_stale_nodes
  install_maestro
  apply_adapter_rbac
  write_adapter_kubeconfig
  log "k3s bootstrap complete"
}

main "$@"
