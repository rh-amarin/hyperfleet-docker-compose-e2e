# HyperFleet Docker Compose E2E Stack

Local HyperFleet control plane (API + RabbitMQ + Sentinels + tier0 adapters + **k3s with Maestro**) for running `hyperfleet-e2e` tier0 tests. By default adapters use the embedded k3s cluster for Kubernetes transport and the in-cluster Maestro server/agent.

See **[REPORT.md](./REPORT.md)** for the full setup narrative, issues encountered, and test results.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│  Docker Compose network                                                             │
│                                                                                     │
│  ┌─────────────────────────────────────┐   ┌───────────────────────────────────┐   │
│  │  HyperFleet control plane           │   │  Maestro (outside k3s)            │   │
│  │                                     │   │                                   │   │
│  │  ┌─────────────────┐                │   │  ┌──────────────────────────────┐ │   │
│  │  │  hyperfleet-api │:8000           │   │  │  maestro-server              │ │   │
│  │  │  (REST API)     │                │   │  │  HTTP :8100  gRPC :8090      │ │   │
│  │  └────────┬────────┘                │   │  └───────┬──────────────────────┘ │   │
│  │           │ SQL                     │   │          │ SQL                    │   │
│  │  ┌────────▼────────┐                │   │  ┌───────▼──────────────────────┐ │   │
│  │  │  postgres       │:5432           │   │  │  maestro-postgres            │ │   │
│  │  │  (hyperfleet)   │                │   │  │  (maestro state)             │ │   │
│  │  └─────────────────┘                │   │  └──────────────────────────────┘ │   │
│  │                                     │   │                                   │   │
│  │  ┌──────────────────────────────┐   │   │  ┌──────────────────────────────┐ │   │
│  │  │  rabbitmq                    │   │   │  │  k3s-maestro-proxy           │ │   │
│  │  │  AMQP :5672  mgmt :15672     │   │   │  │  kubectl port-forward        │ │   │
│  │  └──────┬───────────────────────┘   │   │  │  MQTT :1883 → k3s            │ │   │
│  │         │ AMQP                      │   │  └──────────┬───────────────────┘ │   │
│  │  ┌──────▼───────────────────────┐   │   │             │ MQTT (via proxy)    │   │
│  │  │  sentinel-clusters  :8080    │   │   │  maestro-server ←────────────────┘ │   │
│  │  │  sentinel-nodepools :8080    │   │   └───────────────────────────────────┘   │
│  │  └──────────────────────────────┘   │                                           │
│  └─────────────────────────────────────┘                                           │
│                                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │  Adapters  (all read /kube/config → k3s API, all subscribe to rabbitmq)     │   │
│  │                                                                             │   │
│  │  adapter-cl-namespace   │  adapter-cl-job   │  adapter-cl-deployment        │   │
│  │  adapter-np-configmap   │  adapter-cl-maestro  (also uses maestro gRPC/HTTP)│   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │  k3s  (rancher/k3s — privileged container, single-node cluster)             │   │
│  │                                                                             │   │
│  │  ┌──────────────────────────┐   ┌────────────────────────────────────────┐ │   │
│  │  │  maestro-agent (pod)     │   │  mosquitto / maestro-mqtt (pod)        │ │   │
│  │  │  consumer: cluster1      │   │  MQTT broker  :1883                    │ │   │
│  │  │  connects to mqtt svc    │   │  (k3s-maestro-proxy tunnels this out)  │ │   │
│  │  └──────────────────────────┘   └────────────────────────────────────────┘ │   │
│  │                                                                             │   │
│  │  Namespace: maestro                                                         │   │
│  │  Namespace: hyperfleet  (adapter RBAC — ServiceAccount, ClusterRoleBinding) │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  e2e-runner  (isolated mode only — golang:alpine, runs tier0 test binary)          │
└─────────────────────────────────────────────────────────────────────────────────────┘

Host ports (normal mode):  API :18000  Maestro :8100/:8090  RabbitMQ :5672/:15672
Isolated mode:             no host ports — all traffic inside the compose network
```

**Data flows:**
- Test suite → `hyperfleet-api:8000` (REST) → `postgres`
- `hyperfleet-api` publishes events → `rabbitmq` → sentinels, adapters
- Adapters write Kubernetes resources → `k3s:6443` (via `/kube/config`)
- `adapter-cl-maestro` creates ManifestWorks → `maestro-server:8090` (gRPC)
- `maestro-server` publishes work → MQTT via `k3s-maestro-proxy:1883` → `maestro-mqtt` pod in k3s
- `maestro-agent` pod in k3s applies ManifestWorks → reports status back over MQTT → `maestro-server`

## Quick start

```bash
cd docker-compose-e2e
./scripts/setup.sh      # build images, bootstrap k3s+Maestro, start stack
./scripts/run-tier0.sh  # run 14 tier0 specs in parallel (use --sequential to opt out)
./scripts/teardown.sh   # stop stack and port-forwards
```

## Requirements

- Podman + compose provider
- `helm` (for Maestro chart dependencies)
- `hyperfleet-e2e` checkout at path in `E2E_REPO`
- For `TRANSPORT_TARGET=gke` only: `kubectl` access to GKE + Maestro port-forward

Set `TRANSPORT_TARGET=k3s` (default) for the self-contained k3s + Maestro stack, or `TRANSPORT_TARGET=gke` to use the external GKE cluster.

## Key URLs (defaults)

| Service | URL |
|---------|-----|
| HyperFleet API | http://localhost:18000 |
| Maestro (k3s proxy) | http://localhost:8100 |
| k3s API (host tests) | https://127.0.0.1:16443 (`configs/kube/config-host`) |
| RabbitMQ management | http://localhost:15672 (guest/guest) |

**Note:** Stop any existing Maestro port-forward on port 8100 (e.g. `hf kube port-forward`) before running tests in k3s mode.

## Isolated mode (agent-safe, no host ports)

Use `--isolated` to run with no host ports bound. All traffic stays inside the Docker network and tests execute inside an `e2e-runner` container. Safe to run alongside a running local dev environment.

```bash
./scripts/setup.sh --isolated      # build images, start stack (no host ports)
./scripts/run-tier0.sh --isolated  # run all 14 tier0 specs inside the container
./scripts/teardown.sh --isolated   # stop isolated stack
```

**Single-command orchestrated run** (setup → test → teardown → HTML report):

```bash
./scripts/run-e2e-isolated.sh
```

**Two parallel runs simultaneously** — each run gets a unique `COMPOSE_PROJECT_NAME` so all Docker resources (containers, networks, volumes) are fully namespaced. No port conflicts, no shared state:

```bash
./scripts/run-e2e-isolated.sh &
./scripts/run-e2e-isolated.sh &
wait
# Produces two separate output/report-<ts>.html files
```

**Requirements:** podman-compose ≥1.2 or docker compose ≥2.24 (for YAML `!reset` tag support).

The `e2e-runner` container builds the `hyperfleet-e2e` binary for Linux on first run (cached in external volume `hyperfleet-e2e-bin`, shared across all parallel runs) and writes results to `output/tier0-*/` on the host.
