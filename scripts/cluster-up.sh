#!/usr/bin/env bash
set -euo pipefail

# StepUp one-shot spin-up on Docker Desktop + kind, deployed via Radius.
#   kind  ->  Dapr+Drasi (drasi init)  ->  Radius  ->  shared Redis + drasi-system
#   pub/sub  ->  build/load images  ->  rad deploy (Postgres + 4 services + Dapr
#   components)  ->  webhook secret + sidecar restart  ->  Drasi source/queries/reactions.
# Prereqs: Docker Desktop running; kind, kubectl, rad, drasi, docker on PATH.
# One-time platform bits (drasi init, rad install/init) run/instruct if missing.
# Designed for a FRESH cluster. For a clean re-run: kind delete cluster --name stepup.
# Run from anywhere; paths resolve to the repo root.

CLUSTER=stepup
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# kind must use the Docker provider — clear any stale podman override from the
# abandoned Podman experiment, or `kind load` hits "no nodes found".
unset KIND_EXPERIMENTAL_PROVIDER

# --- 0. Preflight -----------------------------------------------------------
docker info >/dev/null 2>&1 || { echo "Docker Desktop isn't running." >&2; exit 1; }
for t in kind kubectl rad drasi docker; do
  command -v "$t" >/dev/null 2>&1 || { echo "Missing tool: $t" >&2; exit 1; }
done

# --- 1. kind cluster --------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "kind cluster '$CLUSTER' exists."
else
  echo "Creating kind cluster '$CLUSTER'..."
  kind create cluster --name "$CLUSTER"
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# --- 2. Dapr + Drasi control plane (drasi init installs both) ---------------
if kubectl get namespace drasi-system >/dev/null 2>&1; then
  echo "Drasi already installed."
else
  echo "Installing Dapr + Drasi (a few minutes)..."
  drasi init
fi

# --- 3. Radius control plane + environment ----------------------------------
if kubectl get namespace radius-system >/dev/null 2>&1; then
  echo "Radius already installed."
else
  echo "Installing Radius..."
  rad install kubernetes
fi

echo "Configuring Radius environment + recipes..."
bash scripts/radius-recipes.sh

# --- 4. Shared Redis + the drasi-system pub/sub component --------------------
echo "Deploying shared Redis + Dapr pub/sub component..."
kubectl apply -f k8s/redis.yaml
kubectl apply -f k8s/pubsub.yaml   # drasi-system stepup-pubsub (the 'default' one is now unused)
kubectl wait --for=condition=ready pod -l app=redis --timeout=120s

# --- 5. Build + side-load the four service images ---------------------------
echo "Building and loading images..."
for svc in Simulator Clock Notifier Dashboard; do
  img="stepup/$(echo "$svc" | tr '[:upper:]' '[:lower:]'):local"
  docker build -t "$img" "src/$svc"
  kind load docker-image "$img" --name "$CLUSTER"
done

# --- 6. Deploy the app via Radius (Postgres + 4 services + Dapr components) --
echo "Deploying StepUp via Radius..."
rad deploy infra/app.bicep
kubectl wait --for=condition=ready pod -l app=postgres -n default --timeout=180s

# --- 7. Discord webhook secret (app namespace exists now) -------------------
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-$(sed -n 's/.*"discordWebhookUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' src/Notifier/secrets.json 2>/dev/null)}"
[ -n "$WEBHOOK_URL" ] || { echo "Set DISCORD_WEBHOOK_URL or provide src/Notifier/secrets.json." >&2; exit 1; }
kubectl create secret generic notifier-webhook -n default-stepup \
  --from-literal=url="$WEBHOOK_URL" --dry-run=client -o yaml | kubectl apply -f -

# Dapr sidecars only load components/secrets present at startup, and on a fresh
# deploy a container can win the race against its component. Restart the Dapr
# services so they reliably pick up ticker / clock-cron / pub-sub / the secret.
echo "Restarting Dapr services so sidecars load their components..."
for d in simulator clock notifier; do kubectl rollout restart "deploy/$d" -n default-stepup; done
for d in simulator clock notifier; do kubectl rollout status  "deploy/$d" -n default-stepup --timeout=120s; done

# --- 8. Drasi: source -> queries -> reactions -------------------------------
echo "Applying Drasi source..."
drasi apply -f drasi/source.yaml
drasi wait  -f drasi/source.yaml -t 180

echo "Applying Drasi queries..."
for q in behind-pace collective-progress daily-smashed new-leader race-to-goal; do
  drasi apply -f "drasi/$q.yaml"
done

echo "Applying Drasi reactions..."
for r in debug notifier-reaction dashboard-reaction; do
  drasi apply -f "drasi/$r.yaml"
done

cat <<DONE

StepUp is up on the '$CLUSTER' cluster (deployed via Radius).

  Pods:       kubectl get pods -n default-stepup
  Dashboard:  kubectl port-forward -n default-stepup deploy/dashboard 9090:80
              then open http://localhost:9090
  Reactions take ~1 min to go Available: drasi list reaction
  Tear down:  kind delete cluster --name $CLUSTER
DONE