#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${ROOT_DIR}/configs/kube/config"
: "${KUBE_CONTEXT:=gke_hcm-hyperfleet_europe-southwest1-a_hyperfleet-dev-amarin-eu1}"
: "${KUBE_TOKEN_DURATION:=24h}"
: "${KUBE_TOKEN_SA_NAMESPACE:=hyperfleet-e2e-gke1}"
: "${KUBE_TOKEN_SA_NAME:=adapter-clusters-cl-namespace}"

mkdir -p "$(dirname "$OUT_FILE")"

kubectl config use-context "$KUBE_CONTEXT" >/dev/null

CLUSTER_NAME="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
TOKEN="$(kubectl create token "${KUBE_TOKEN_SA_NAME}" -n "${KUBE_TOKEN_SA_NAMESPACE}" --duration="${KUBE_TOKEN_DURATION}")"

cat >"$OUT_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: e2e-token-user
  name: ${CLUSTER_NAME}
current-context: ${CLUSTER_NAME}
users:
- name: e2e-token-user
  user:
    token: ${TOKEN}
EOF

chmod 600 "$OUT_FILE"
echo "Wrote token-based kubeconfig to ${OUT_FILE} (context: ${CLUSTER_NAME})"
