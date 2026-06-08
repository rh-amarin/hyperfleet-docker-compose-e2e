#!/usr/bin/env bash
# Full isolated E2E run: setup → test (parallel) → teardown → HTML report.
# Produces output/report-<timestamp>.html viewable in any browser.
#
# Each invocation gets a unique COMPOSE_PROJECT_NAME so two runs can execute
# simultaneously without any resource conflicts (containers, networks, volumes).
#
# Usage:
#   ./scripts/run-e2e-isolated.sh [--skip-build]
#
# Parallel:
#   ./scripts/run-e2e-isolated.sh &
#   ./scripts/run-e2e-isolated.sh &
#   wait
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

SKIP_BUILD="${SKIP_BUILD:-false}"
for arg in "$@"; do [[ "$arg" == "--skip-build" ]] && SKIP_BUILD=true; done

REPORT_DIR="${ROOT_DIR}/output"
mkdir -p "$REPORT_DIR"

log() { printf '\033[1;34m[e2e]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[e2e]\033[0m %s\n' "$*" >&2; }

# ── Detect container runtime ──────────────────────────────────────────────────
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD="podman"
  _BASE_COMPOSE="podman compose"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD="docker"
  _BASE_COMPOSE="docker compose"
else
  err "ERROR: neither podman nor docker found in PATH"; exit 1
fi

# ── Generate unique run identity ──────────────────────────────────────────────
# Each invocation gets a 6-char hex ID so parallel runs are fully isolated:
# containers, networks, and named volumes (kube-config, k3s-data) are all
# namespaced by COMPOSE_PROJECT_NAME automatically.
RUN_ID="$(openssl rand -hex 3)"
PROJECT_NAME="hyperfleet-e2e-${RUN_ID}"
# Embed --project-name in COMPOSE_CMD so all sub-scripts pick it up without
# needing further changes.
export COMPOSE_CMD="${_BASE_COMPOSE} --project-name ${PROJECT_NAME}"
log "Run ID: ${RUN_ID}  project: ${PROJECT_NAME}  runtime: ${CONTAINER_CMD}"

# ── Ensure shared binary cache volume exists ──────────────────────────────────
# Declared as external in docker-compose.isolated.yml so it is NOT namespaced
# by project name — all parallel runs share the same compiled binary.
${CONTAINER_CMD} volume create hyperfleet-e2e-bin 2>/dev/null || true

# ── 1. Setup ──────────────────────────────────────────────────────────────────
log "Starting isolated stack (SKIP_BUILD=${SKIP_BUILD}, project=${PROJECT_NAME})"
SKIP_BUILD="$SKIP_BUILD" ./scripts/setup.sh --isolated

# ── 2. Run tier0 tests ────────────────────────────────────────────────────────
# Pin the timestamp NOW so we know exactly which output dir was created.
RUN_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
log "Running tier0 tests in parallel (inside container, output: tier0-${RUN_TIMESTAMP})"
TEST_EXIT=0
EXTERNAL_TIMESTAMP="$RUN_TIMESTAMP" ./scripts/run-tier0.sh --isolated || TEST_EXIT=$?

# ── 3. Teardown ───────────────────────────────────────────────────────────────
log "Tearing down isolated stack (project=${PROJECT_NAME})"
./scripts/teardown.sh --isolated

# ── 4. Locate run directory ───────────────────────────────────────────────────
RUN_DIR="${REPORT_DIR}/tier0-${RUN_TIMESTAMP}"
if [[ ! -d "$RUN_DIR" ]]; then
  err "No test output found at ${RUN_DIR}"
  exit 1
fi

# ── 5. Parse results ──────────────────────────────────────────────────────────
TESTS=(
  "cluster-creation-workflow"
  "cluster-creation-k8s-resources"
  "cluster-creation-adapter-dependency"
  "cluster-update"
  "cluster-delete-lifecycle"
  "cluster-delete-conflict"
  "cluster-cascade-delete"
  "nodepool-creation-workflow"
  "nodepool-creation-k8s-resources"
  "nodepool-update"
  "nodepool-delete-lifecycle"
  "nodepool-delete-conflict"
  "adapter-maestro-happy-path"
  "adapter-maestro-idempotency"
)

declare -a ROWS=()
PASSED=0
FAILED=0
MAX_DUR=0

for name in "${TESTS[@]}"; do
  result="$(cat "${RUN_DIR}/${name}.status" 2>/dev/null || echo UNKNOWN)"
  dur="$(cat "${RUN_DIR}/${name}.duration" 2>/dev/null || echo 0)"
  [[ $dur -gt $MAX_DUR ]] && MAX_DUR=$dur
  if [[ "$result" == "PASS" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  # Escape any log snippet for HTML (first failure line from log)
  snippet=""
  if [[ -f "${RUN_DIR}/${name}.log" ]]; then
    snippet="$(grep -m1 -iE 'FAIL|Error|panic' "${RUN_DIR}/${name}.log" 2>/dev/null | \
      sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' | head -c 200 || true)"
  fi
  ROWS+=("${name}|${result}|${dur}|${snippet}")
done

TOTAL=$((PASSED + FAILED))
OVERALL="PASS"
[[ $FAILED -gt 0 ]] && OVERALL="FAIL"

# ── 6. Generate HTML report ───────────────────────────────────────────────────
REPORT_FILE="${REPORT_DIR}/report-${RUN_TIMESTAMP}.html"
# Pre-compute bash 4+ expressions so they work on system bash 3.x.
OVERALL_LOWER="$(printf '%s' "$OVERALL" | tr '[:upper:]' '[:lower:]')"
FAILED_COLOR="$([ $FAILED -eq 0 ] && echo 'var(--pass)' || echo 'var(--fail)')"

rows_html=""
for row in "${ROWS[@]}"; do
  IFS='|' read -r name result dur snippet <<< "$row"
  if [[ "$result" == "PASS" ]]; then
    badge='<span class="badge pass">PASS</span>'
    row_class="pass-row"
  else
    badge='<span class="badge fail">FAIL</span>'
    row_class="fail-row"
  fi
  bar_pct=0
  [[ $MAX_DUR -gt 0 ]] && bar_pct=$(( dur * 100 / MAX_DUR ))
  snippet_html=""
  [[ -n "$snippet" ]] && snippet_html="<div class=\"snippet\">${snippet}</div>"
  log_link="tier0-${RUN_TIMESTAMP}/${name}.log"
  rows_html+="
    <tr class=\"${row_class}\">
      <td>${badge}</td>
      <td><a href=\"${log_link}\" target=\"_blank\">${name}</a></td>
      <td>
        <div class=\"bar-wrap\"><div class=\"bar\" style=\"width:${bar_pct}%\"></div></div>
        <span class=\"dur\">${dur}s</span>
      </td>
      <td>${snippet_html}</td>
    </tr>"
done

cat >"$REPORT_FILE" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HyperFleet E2E — Tier0 Report</title>
<style>
  :root {
    --pass: #22c55e; --fail: #ef4444; --bg: #0f172a; --surface: #1e293b;
    --border: #334155; --text: #e2e8f0; --muted: #94a3b8; --accent: #38bdf8;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: 'SF Mono', 'Fira Code', monospace; font-size: 13px; padding: 32px; }
  h1 { font-size: 20px; font-weight: 700; color: var(--accent); margin-bottom: 4px; }
  .meta { color: var(--muted); font-size: 11px; margin-bottom: 28px; }
  .summary { display: flex; gap: 24px; margin-bottom: 32px; flex-wrap: wrap; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 20px 28px; min-width: 140px; }
  .card .label { font-size: 10px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin-bottom: 6px; }
  .card .value { font-size: 28px; font-weight: 700; }
  .card.overall-pass .value { color: var(--pass); }
  .card.overall-fail .value { color: var(--fail); }
  .card .sub { font-size: 11px; color: var(--muted); margin-top: 4px; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; padding: 8px 12px; font-size: 10px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); border-bottom: 1px solid var(--border); }
  td { padding: 10px 12px; border-bottom: 1px solid var(--border); vertical-align: middle; }
  .pass-row td:first-child { border-left: 3px solid var(--pass); }
  .fail-row td:first-child { border-left: 3px solid var(--fail); }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; letter-spacing: .04em; }
  .badge.pass { background: #14532d; color: var(--pass); }
  .badge.fail { background: #450a0a; color: var(--fail); }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .bar-wrap { background: #0f172a; border-radius: 3px; height: 4px; width: 120px; display: inline-block; vertical-align: middle; margin-right: 8px; }
  .bar { background: var(--accent); height: 4px; border-radius: 3px; }
  .dur { color: var(--muted); font-size: 11px; }
  .snippet { font-size: 10px; color: #f87171; margin-top: 4px; opacity: .8; white-space: pre-wrap; word-break: break-all; }
  tr:hover td { background: rgba(255,255,255,.02); }
</style>
</head>
<body>
<h1>HyperFleet — Tier0 E2E Report</h1>
<p class="meta">Run: ${RUN_TIMESTAMP} &nbsp;|&nbsp; Isolated mode (no host ports) &nbsp;|&nbsp; 14 specs in parallel</p>

<div class="summary">
  <div class="card overall-${OVERALL_LOWER}">
    <div class="label">Overall</div>
    <div class="value">${OVERALL}</div>
  </div>
  <div class="card">
    <div class="label">Passed</div>
    <div class="value" style="color:var(--pass)">${PASSED}</div>
    <div class="sub">of ${TOTAL}</div>
  </div>
  <div class="card">
    <div class="label">Failed</div>
    <div class="value" style="color:${FAILED_COLOR}">${FAILED}</div>
  </div>
  <div class="card">
    <div class="label">Wall time</div>
    <div class="value" style="font-size:20px;padding-top:4px">${MAX_DUR}s</div>
    <div class="sub">(slowest test)</div>
  </div>
</div>

<table>
  <thead>
    <tr><th>Result</th><th>Test</th><th>Duration</th><th>Failure hint</th></tr>
  </thead>
  <tbody>
    ${rows_html}
  </tbody>
</table>
</body>
</html>
HTML

log "Report written: ${REPORT_FILE}"
log "Results dir:    ${RUN_DIR}"

if [[ $FAILED -gt 0 ]]; then
  err "FAILED: ${FAILED}/${TOTAL} tests"
  exit 1
fi
log "All ${TOTAL} tests PASSED"
