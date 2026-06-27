#!/usr/bin/env bash
set -euo pipefail

# StepUp teardown — companion to cluster-up.sh.
#   (default)         remove the app + Drasi resources + data, but KEEP the kind
#                     cluster and the Dapr/Drasi/Radius control planes so a
#                     re-run of cluster-up.sh redeploys quickly.
#   --all | --cluster delete the entire kind cluster (full reset).
# Run from anywhere; paths resolve to the repo root.

CLUSTER=stepup
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

unset KIND_EXPERIMENTAL_PROVIDER

MODE="app"
case "${1:-}" in
  --all|--cluster) MODE="cluster" ;;
  "")              ;;
  *)               echo "Usage: $0 [--all]" >&2; exit 1 ;;
esac

# --- Full reset: nuke the whole cluster -------------------------------------
if [ "$MODE" = "cluster" ]; then
  echo "Deleting kind cluster '$CLUSTER'..."
  kind delete cluster --name "$CLUSTER"
  echo "Done — cluster removed."
  exit 0
fi

# --- App teardown (keep the cluster + control planes) -----------------------
kubectl config use-context "kind-$CLUSTER" >/dev/null 2>&1 || {
  echo "Cluster '$CLUSTER' not found — nothing to tear down."; exit 0; }

echo "Deleting Drasi reactions, queries, source..."
for r in dashboard-reaction notifier-reaction debug; do
  drasi delete -f "drasi/$r.yaml" 2>/dev/null || true
done
for q in behind-pace collective-progress daily-smashed new-leader race-to-goal; do
  drasi delete -f "drasi/$q.yaml" 2>/dev/null || true
done
drasi delete -f drasi/source.yaml 2>/dev/null || true

echo "Deleting the Radius app..."
rad app delete stepup --yes 2>/dev/null || true

# Safety net: drop the raw-k8s Postgres (in 'default') in case Radius left it,
# the shared Redis + pub/sub component, and the app namespace (secret + Dapr
# components). Removing Redis also clears the stepup-events stream, so the next
# spin-up starts clean (no stale-event replay).
echo "Cleaning up Postgres, Redis, and the app namespace..."
kubectl delete deploy/postgres svc/postgres configmap/stepup-initdb pvc/postgres-data \
  -n default --ignore-not-found
kubectl delete -f k8s/redis.yaml --ignore-not-found
kubectl delete -f k8s/pubsub.yaml --ignore-not-found
kubectl delete namespace default-stepup --ignore-not-found

cat <<DONE

StepUp app torn down (cluster '$CLUSTER' and control planes kept).
  Re-deploy:   ./scripts/cluster-up.sh
  Full reset:  ./scripts/cluster-down.sh --all
DONE