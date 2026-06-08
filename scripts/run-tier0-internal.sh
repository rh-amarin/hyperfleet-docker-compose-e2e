#!/bin/sh
# Runs inside the e2e-runner container in isolated mode.
# All environment variables (HYPERFLEET_API_URL, MAESTRO_URL, KUBECONFIG, etc.)
# are injected by docker-compose.isolated.yml.
set -eu

BINARY=/e2e/bin/hyperfleet-e2e

# Build Linux binary from mounted source if not already cached in the e2e-bin volume.
if [ ! -x "$BINARY" ]; then
  echo "[runner] Building hyperfleet-e2e Linux binary..."
  (cd /e2e && CGO_ENABLED=0 go build -o bin/hyperfleet-e2e ./cmd/hyperfleet-e2e)
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${OUTPUT_DIR:-/output/tier0-${TIMESTAMP}}"
mkdir -p "$RUN_DIR"

echo "[runner] API:       ${HYPERFLEET_API_URL}"
echo "[runner] Maestro:   ${MAESTRO_URL}"
echo "[runner] Namespace: ${NAMESPACE}"
echo "[runner] Output:    ${RUN_DIR}"
echo ""

# Write test definitions to a temp file so IFS-splitting doesn't destroy
# multi-word focus patterns when iterating. Format: name<TAB>focus
TESTS_FILE="$(mktemp)"
PIDS_FILE="$(mktemp)"
trap 'rm -f "$TESTS_FILE" "$PIDS_FILE"' EXIT

cat >"$TESTS_FILE" <<'EOF'
cluster-creation-workflow	Cluster Resource Type Lifecycle.*should validate complete workflow from creation to Reconciled state
cluster-creation-k8s-resources	should create Kubernetes resources with correct templated values for adapters that create K8s resources
cluster-creation-adapter-dependency	should validate cl-deployment dependency on cl-job with comprehensive condition checks
cluster-update	should update cluster via PATCH, trigger reconciliation, and reach Reconciled at new generation
cluster-delete-lifecycle	Cluster Deletion Lifecycle.*should complete full deletion lifecycle from soft-delete through hard-delete
cluster-delete-conflict	should return 409 Conflict when PATCHing a soft-deleted cluster
cluster-cascade-delete	should cascade deletion to child nodepools and hard-delete all resources
nodepool-creation-workflow	NodePool Resource Type Lifecycle.*should validate complete workflow from creation to Reconciled state
nodepool-creation-k8s-resources	should create Kubernetes resources with correct templated values for all required adapters
nodepool-update	should update nodepool via PATCH, trigger reconciliation, and reach Reconciled at new generation
nodepool-delete-lifecycle	NodePool Deletion Lifecycle.*should complete full deletion lifecycle from soft-delete through hard-delete
nodepool-delete-conflict	should return 409 Conflict when PATCHing a soft-deleted nodepool
adapter-maestro-happy-path	should create ManifestWork and report status via Maestro transport
adapter-maestro-idempotency	should skip ManifestWork operation when generation is unchanged
EOF

# Launch all tests in parallel. Use a file for PIDs because subshells can't
# write back to parent-shell variables.
while IFS='	' read -r name focus; do
  [ -z "$name" ] && continue
  (
    logfile="${RUN_DIR}/${name}.log"
    t0="$(date +%s)"
    if (cd /e2e && "$BINARY" test --label-filter=tier0 --focus "$focus" --log-level=info) >"$logfile" 2>&1; then
      echo "PASS" >"${RUN_DIR}/${name}.status"
    else
      echo "FAIL" >"${RUN_DIR}/${name}.status"
    fi
    t1="$(date +%s)"
    dur=$((t1 - t0))
    echo "$dur" >"${RUN_DIR}/${name}.duration"
    result="$(cat "${RUN_DIR}/${name}.status")"
    printf "  [%-4s] (%ds) %s\n" "$result" "$dur" "$name"
  ) &
  echo $! >>"$PIDS_FILE"
done < "$TESTS_FILE"

echo "--- running 14 tests in parallel (logs: ${RUN_DIR}) ---"

# Wait for every background test process.
while IFS= read -r pid; do
  wait "$pid" 2>/dev/null || true
done < "$PIDS_FILE"

echo ""

# Collect results.
PASSED=0
FAILED=0
FAILED_NAMES=""
while IFS='	' read -r name focus; do
  [ -z "$name" ] && continue
  result="$(cat "${RUN_DIR}/${name}.status" 2>/dev/null || echo UNKNOWN)"
  if [ "$result" = "PASS" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES="${FAILED_NAMES} ${name}"
  fi
done < "$TESTS_FILE"

summary_file="${RUN_DIR}/summary.txt"
{
  echo "Tier0 test run summary (${TIMESTAMP})"
  echo "Passed: ${PASSED} / $((PASSED + FAILED))"
  echo "Failed: ${FAILED}"
  if [ -n "$FAILED_NAMES" ]; then
    echo "Failed tests:${FAILED_NAMES}"
  fi
  echo ""
  echo "Timing:"
  while IFS='	' read -r name focus; do
    [ -z "$name" ] && continue
    result="$(cat "${RUN_DIR}/${name}.status" 2>/dev/null || echo UNKNOWN)"
    dur="$(cat "${RUN_DIR}/${name}.duration" 2>/dev/null || echo 0)"
    printf "  %-4s  %3ds  %s\n" "$result" "$dur" "$name"
  done < "$TESTS_FILE"
} | tee "$summary_file"

echo ""
echo "Summary: ${RUN_DIR}/summary.txt"

[ "$FAILED" -eq 0 ]
