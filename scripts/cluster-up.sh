#!/usr/bin/env bash
set -euo pipefail

# Sets up the StepUp local environment on Docker Desktop + kind:
#   kind cluster  ->  in-cluster Postgres  ->  Drasi control plane  ->  source + debug query
# Prereqs: Docker Desktop running; kind, kubectl, and drasi CLIs installed.
# Run from anywhere — paths resolve relative to the repo root.

CLUSTER=stepup
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- 0. Docker Desktop must be running ---
if ! docker info >/dev/null 2>&1; then
  echo "Docker Desktop isn't running. Start it and re-run." >&2
  exit 1
fi

# --- 1. kind cluster (Docker provider) ---
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "kind cluster '$CLUSTER' already exists."
else
  echo "Creating kind cluster '$CLUSTER'..."
  kind create cluster --name "$CLUSTER"
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# --- 2. In-cluster Postgres (schema + seed + drasi role via ConfigMap) ---
echo "Applying init SQL ConfigMap..."
kubectl create configmap stepup-initdb \
  --from-file=01-schema.sql=data/schema.sql \
  --from-file=02-seed.sql=data/seed.sql \
  --from-file=03-drasi.sql=data/drasi-setup.sql \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying Postgres..."
kubectl apply -f k8s/postgres.yaml
kubectl wait --for=condition=ready pod -l app=postgres --timeout=120s

# --- 3. Drasi control plane (skips if already installed) ---
if kubectl get namespace drasi-system >/dev/null 2>&1; then
  echo "Drasi already installed (drasi-system exists)."
else
  echo "Installing Drasi (pulls several images, takes a few minutes)..."
  drasi init
fi

# --- 4. Drasi source + debug query/reaction ---
echo "Applying Drasi source..."
drasi apply -f drasi/source.yaml
drasi wait -f drasi/source.yaml -t 180

echo "Applying debug query + reaction..."
drasi apply -f drasi/debug.yaml
drasi wait -f drasi/debug.yaml -t 180

cat <<DONE

StepUp is up on the '$CLUSTER' cluster.
  watch a query:       drasi watch all-participants
  port-forward the DB: kubectl port-forward svc/postgres 5432:5432
  source status:       drasi list source
DONE