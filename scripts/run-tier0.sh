#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${E2E_REPO:=/Users/amarin/work/workspaces/github/hyperfleet/hyperfleet-e2e/ue2e/main}"
: "${NAMESPACE:=hyperfleet-e2e-compose}"
: "${MAESTRO_HTTP_PORT:=8100}"
: "${TRANSPORT_TARGET:=k3s}"

# Detect container runtime (podman preferred, docker fallback).
if command -v podman >/dev/null 2>&1; then
  COMPOSE_CMD="${COMPOSE_CMD:-podman compose}"
elif command -v docker >/dev/null 2>&1; then
  COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"
else
  echo "ERROR: neither podman nor docker found in PATH" >&2; exit 1
fi
ISOLATED=false

# Each entry: "name|focus-regex"
TESTS=(
  "cluster-creation-workflow|Cluster Resource Type Lifecycle.*should validate complete workflow from creation to Reconciled state"
  "cluster-creation-k8s-resources|should create Kubernetes resources with correct templated values for adapters that create K8s resources"
  "cluster-creation-adapter-dependency|should validate cl-deployment dependency on cl-job with comprehensive condition checks"
  "cluster-update|should update cluster via PATCH, trigger reconciliation, and reach Reconciled at new generation"
  "cluster-delete-lifecycle|Cluster Deletion Lifecycle.*should complete full deletion lifecycle from soft-delete through hard-delete"
  "cluster-delete-conflict|should return 409 Conflict when PATCHing a soft-deleted cluster"
  "cluster-cascade-delete|should cascade deletion to child nodepools and hard-delete all resources"
  "nodepool-creation-workflow|NodePool Resource Type Lifecycle.*should validate complete workflow from creation to Reconciled state"
  "nodepool-creation-k8s-resources|should create Kubernetes resources with correct templated values for all required adapters"
  "nodepool-update|should update nodepool via PATCH, trigger reconciliation, and reach Reconciled at new generation"
  "nodepool-delete-lifecycle|NodePool Deletion Lifecycle.*should complete full deletion lifecycle from soft-delete through hard-delete"
  "nodepool-delete-conflict|should return 409 Conflict when PATCHing a soft-deleted nodepool"
  "adapter-maestro-happy-path|should create ManifestWork and report status via Maestro transport"
  "adapter-maestro-idempotency|should skip ManifestWork operation when generation is unchanged"
)

DRY_RUN=false
SEQUENTIAL=false
FILTER_TEST=""

export HYPERFLEET_API_URL="${HYPERFLEET_API_URL:-http://localhost:${API_HOST_PORT:-18000}}"
export MAESTRO_URL="${MAESTRO_URL:-http://localhost:${MAESTRO_HTTP_PORT}}"
export NAMESPACE
if [[ "${TRANSPORT_TARGET:-k3s}" == "k3s" && -f "${ROOT_DIR}/configs/kube/config-host" ]]; then
  export KUBECONFIG="${ROOT_DIR}/configs/kube/config-host"
fi
export TESTDATA_DIR="${E2E_REPO}/testdata"
export HYPERFLEET_ADAPTERS_CLUSTER="${HYPERFLEET_ADAPTERS_CLUSTER:-cl-namespace,cl-job,cl-deployment,cl-maestro}"
export HYPERFLEET_ADAPTERS_NODEPOOL="${HYPERFLEET_ADAPTERS_NODEPOOL:-np-configmap}"

BINARY="${E2E_REPO}/bin/hyperfleet-e2e"
RESULTS_DIR="${ROOT_DIR}/output"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${RESULTS_DIR}/tier0-${TIMESTAMP}"

fmt_duration() {
  local secs=$1
  if [[ $secs -ge 60 ]]; then
    printf "%dm%02ds" $((secs / 60)) $((secs % 60))
  else
    printf "%ds" "$secs"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run each tier0 E2E test in a separate process (parallel by default).

Options:
  --list                List all tests with their index and focus pattern
  --test <name|index>   Run a single test by name or 1-based index
  --sequential          Run tests one after another (default: parallel)
  --dry-run             Print commands without executing them
  --isolated            Run tests inside the e2e-runner container (no host ports)
  -h, --help            Show this help

Environment (from .env or shell):
  E2E_REPO, HYPERFLEET_API_URL, MAESTRO_URL, NAMESPACE, API_HOST_PORT

Examples:
  $(basename "$0")
  $(basename "$0") --sequential
  $(basename "$0") --isolated
  $(basename "$0") --list
  $(basename "$0") --test cluster-creation-adapter-dependency
EOF
}

list_tests() {
  printf "%-4s  %-40s  %s\n" "#" "NAME" "FOCUS PATTERN"
  printf "%-4s  %-40s  %s\n" "---" "----------------------------------------" "--------------------------------------------"
  local i=1
  for entry in "${TESTS[@]}"; do
    local name focus
    name="${entry%%|*}"
    focus="${entry##*|}"
    printf "%-4s  %-40s  %s\n" "$i" "$name" "$focus"
    ((i++))
  done
}

resolve_test() {
  local filter="$1"
  if [[ "$filter" =~ ^[0-9]+$ ]]; then
    local idx=$((filter - 1))
    if [[ $idx -lt 0 || $idx -ge ${#TESTS[@]} ]]; then
      echo "Error: index $filter out of range (1-${#TESTS[@]})" >&2
      exit 1
    fi
    echo "${TESTS[$idx]}"
    return
  fi
  for entry in "${TESTS[@]}"; do
    local name="${entry%%|*}"
    if [[ "$name" == "$filter" ]]; then
      echo "$entry"
      return
    fi
  done
  echo "Error: test '$filter' not found. Use --list to see available tests." >&2
  exit 1
}

run_test() {
  local name="$1"
  local focus="$2"
  local logfile="${3:-}"

  if [[ -n "$logfile" ]]; then
    echo "==> [$name] log: $logfile"
  else
    echo ""
    echo "==> [$name]"
    echo "    focus: $focus"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    cmd: (cd ${E2E_REPO} && ./bin/hyperfleet-e2e test --label-filter=tier0 --focus \"${focus}\")"
    return 0
  fi

  if [[ -n "$logfile" ]]; then
    (
      cd "$E2E_REPO"
      ./bin/hyperfleet-e2e test \
        --label-filter=tier0 \
        --focus "$focus" \
        --log-level=info
    ) >"$logfile" 2>&1
  else
    (
      cd "$E2E_REPO"
      ./bin/hyperfleet-e2e test \
        --label-filter=tier0 \
        --focus "$focus" \
        --log-level=info
    )
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --list)
    list_tests
    exit 0
    ;;
  --test)
    shift
    FILTER_TEST="${1:-}"
    if [[ -z "$FILTER_TEST" ]]; then
      echo "Error: --test requires a name or index argument" >&2
      exit 1
    fi
    ;;
  --sequential)
    SEQUENTIAL=true
    ;;
  --dry-run)
    DRY_RUN=true
    ;;
  --isolated)
    ISOLATED=true
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Error: unknown option '$1'" >&2
    usage >&2
    exit 1
    ;;
  esac
  shift
done

if $ISOLATED; then
  if [[ "${TRANSPORT_TARGET}" == "k3s" ]]; then
    _base="${ROOT_DIR}/docker-compose.yml"
  else
    _base="${ROOT_DIR}/docker-compose.gke.yml"
  fi
  COMPOSE_FLAGS="-f ${_base} -f ${ROOT_DIR}/docker-compose.isolated.yml"
  # Allow orchestration scripts to pin the timestamp so they know which output dir to read.
  TIMESTAMP="${EXTERNAL_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
  echo "Running tier0 tests inside e2e-runner container (isolated mode)"
  echo "  Output: ${ROOT_DIR}/output/tier0-${TIMESTAMP}"
  # shellcheck disable=SC2086
  ${COMPOSE_CMD} ${COMPOSE_FLAGS} --env-file .env \
    --profile runner \
    run --rm \
    -e OUTPUT_DIR="/output/tier0-${TIMESTAMP}" \
    e2e-runner /scripts/run-tier0-internal.sh
  exit $?
fi

if [[ ! -x "$BINARY" ]]; then
  echo "Building hyperfleet-e2e binary in ${E2E_REPO}"
  (cd "$E2E_REPO" && make build)
fi

mkdir -p "$RUN_DIR"

declare -a selected=()
if [[ -n "$FILTER_TEST" ]]; then
  selected+=("$(resolve_test "$FILTER_TEST")")
else
  selected=("${TESTS[@]}")
fi

echo "Running tier0 tests"
echo "  Mode:      $(if [[ "$SEQUENTIAL" == "true" || ${#selected[@]} -eq 1 ]]; then echo sequential; else echo parallel; fi)"
echo "  API:       ${HYPERFLEET_API_URL}"
echo "  Maestro:   ${MAESTRO_URL}"
echo "  Namespace: ${NAMESPACE}"
echo "  E2E repo:  ${E2E_REPO}"
echo "  Output:    ${RUN_DIR}"

declare -a passed=()
declare -a failed=()
declare -a durations=()

t_wall_start=$(date +%s)

if [[ "$SEQUENTIAL" != "true" && ${#selected[@]} -gt 1 ]]; then
  declare -a par_names=()
  declare -a par_pids=()
  local_total=${#selected[@]}

  for entry in "${selected[@]}"; do
    name="${entry%%|*}"
    focus="${entry##*|}"
    logfile="${RUN_DIR}/${name}.log"
    (
      t0=$(date +%s)
      if run_test "$name" "$focus" "$logfile"; then
        result="PASS"
      else
        result="FAIL"
      fi
      t1=$(date +%s)
      echo $((t1 - t0)) >"${RUN_DIR}/${name}.duration"
      echo "$result" >"${RUN_DIR}/${name}.status"
    ) &
    par_names+=("$name")
    par_pids+=($!)
  done

  echo ""
  echo "--- running ${local_total} tests in parallel (logs: ${RUN_DIR}) ---"
  echo ""

  (
    declare -a reported=()
    while [[ ${#reported[@]} -lt $local_total ]]; do
      for statusfile in "${RUN_DIR}"/*.status; do
        [[ -f "$statusfile" ]] || continue
        sname="$(basename "$statusfile" .status)"
        already=false
        for r in "${reported[@]:-x}"; do [[ "$r" == "$sname" ]] && already=true && break; done
        if [[ "$already" == "false" ]]; then
          result="$(cat "$statusfile")"
          dur_secs="$(cat "${RUN_DIR}/${sname}.duration" 2>/dev/null || echo 0)"
          reported+=("$sname")
          printf "  [%d/%d] %-4s  (%s)  %s\n" \
            "${#reported[@]}" "$local_total" "$result" "$(fmt_duration "$dur_secs")" "$sname"
        fi
      done
      sleep 1
    done
  ) &
  monitor_pid=$!

  for pid in "${par_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  wait "$monitor_pid" 2>/dev/null || true

  echo ""
  echo "--- logs ---"
  for name in "${par_names[@]}"; do
    result="$(cat "${RUN_DIR}/${name}.status" 2>/dev/null || echo "UNKNOWN")"
    dur_secs="$(cat "${RUN_DIR}/${name}.duration" 2>/dev/null || echo 0)"
    printf "  %-4s  (%s)  %s\n" "$result" "$(fmt_duration "$dur_secs")" "${RUN_DIR}/${name}.log"
    durations+=("$dur_secs")
    if [[ "$result" == "PASS" ]]; then
      passed+=("$name")
    else
      failed+=("$name")
    fi
  done

  timing_names=("${par_names[@]}")
else
  timing_names=()
  for entry in "${selected[@]}"; do
    name="${entry%%|*}"
    focus="${entry##*|}"
    timing_names+=("$name")
    logfile="${RUN_DIR}/${name}.log"
    t0=$(date +%s)
    if run_test "$name" "$focus" "$logfile"; then
      passed+=("$name")
      echo "PASS" >"${RUN_DIR}/${name}.status"
    else
      failed+=("$name")
      echo "FAIL" >"${RUN_DIR}/${name}.status"
    fi
    t1=$(date +%s)
    dur=$((t1 - t0))
    durations+=("$dur")
    echo "$dur" >"${RUN_DIR}/${name}.duration"
  done
fi

t_wall_end=$(date +%s)
t_wall_total=$((t_wall_end - t_wall_start))

summary_file="${RUN_DIR}/summary.txt"
{
  echo "Tier0 test run summary (${TIMESTAMP})"
  echo "Passed: ${#passed[@]}"
  for t in "${passed[@]:-}"; do [[ -n "$t" ]] && echo "  PASS  $t"; done
  echo "Failed: ${#failed[@]}"
  for t in "${failed[@]:-}"; do [[ -n "$t" ]] && echo "  FAIL  $t"; done
  echo ""
  echo "Timing:"
  for i in "${!timing_names[@]}"; do
    printf "  %-40s  %s\n" "${timing_names[$i]}" "$(fmt_duration "${durations[$i]:-0}")"
  done
  printf "Wall time: %s\n" "$(fmt_duration "$t_wall_total")"
} | tee "$summary_file"

echo ""
echo "Summary: ${RUN_DIR}/summary.txt"

[[ ${#failed[@]} -eq 0 ]]
