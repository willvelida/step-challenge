#!/usr/bin/env bash
set -euo pipefail

# StepUp cloud spin-up on AKS — the Azure sibling of cluster-up.sh.
#   infra (RG/AKS/ACR) -> start cluster -> build/push images (az acr build) ->
#   Dapr+Drasi+Radius -> Redis + pub/sub -> webhook secret -> rad deploy -> Drasi.
# Prereqs: `az login` done; az, kubectl, rad, drasi, docker on PATH; Owner (or
#   User Access Administrator) on the subscription for the infra role assignment;
#   the Radius env 'default' set up once on this cluster (`rad init`).
# Bakes in the first-run lessons: 4 nodes, az acr build (native amd64, no QEMU),
#   secret-before-deploy, rm -rf ~/.drasi.
# Run from anywhere; paths resolve to the repo root.

RG=stepup-rg
AKS=stepup-aks
ACR=stepupacr2026
LOCATION=australiaeast
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- 0. Preflight -----------------------------------------------------------
for t in az kubectl rad drasi docker; do
  command -v "$t" >/dev/null 2>&1 || { echo "Missing tool: $t" >&2; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Run 'az login' first." >&2; exit 1; }

# --- 1. Provision infra only if the cluster doesn't exist (first run, ~10m) --
#        To apply main.bicepparam changes later, run az deployment sub create by hand.
if ! az aks show -g "$RG" -n "$AKS" >/dev/null 2>&1; then
  echo "Provisioning infra (RG/AKS/ACR)... first run, several minutes."
  az deployment sub create -n stepup -l "$LOCATION" --parameters infra/main.bicepparam
fi

# --- 2. Ensure the cluster is running + point kubectl at it ------------------
if [ "$(az aks show -g "$RG" -n "$AKS" --query powerState.code -o tsv)" != "Running" ]; then
  echo "Starting AKS..."
  az aks start -g "$RG" -n "$AKS"
fi
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing

# drasi caches its target context in ~/.drasi — clear it so every drasi command
# targets AKS (current context), not a stale kind cache.
rm -rf ~/.drasi

# --- 3. Build + push the four images to ACR (native amd64 via az acr build) --
echo "Building and pushing images to ACR..."
TAG=$(git rev-parse --short HEAD)
for svc in Simulator Clock Notifier Dashboard; do
  name=$(echo "$svc" | tr '[:upper:]' '[:lower:]')
  az acr build -r "$ACR" -t "$name:$TAG" --platform linux/amd64 "src/$svc"
done

# --- 4. Dapr + Drasi + Radius control planes (skip if present) ---------------
if kubectl get namespace drasi-system >/dev/null 2>&1; then
  echo "Drasi already installed."
else
  echo "Installing Dapr + Drasi..."
  drasi init
fi
if kubectl get namespace radius-system >/dev/null 2>&1; then
  echo "Radius already installed."
else
  echo "Installing Radius..."
  rad install kubernetes
fi
rad env show default >/dev/null 2>&1 || {
  echo "No Radius env 'default' on this cluster. Run 'rad init' once, then re-run." >&2; exit 1; }
rad workspace show

# --- 5. Shared Redis + the drasi-system pub/sub component --------------------
kubectl apply -f k8s/redis.yaml
kubectl apply -f k8s/pubsub.yaml
kubectl wait --for=condition=ready pod -l app=redis --timeout=120s

# --- 6. Webhook secret BEFORE rad deploy (so the notifier never starts -------
#        without it — that crashed the notifier on the first manual run) ------
kubectl create namespace default-stepup --dry-run=client -o yaml | kubectl apply -f -
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-$(sed -n 's/.*"discordWebhookUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' src/Notifier/secrets.json 2>/dev/null)}"
[ -n "$WEBHOOK_URL" ] || { echo "Set DISCORD_WEBHOOK_URL or provide src/Notifier/secrets.json." >&2; exit 1; }
kubectl create secret generic notifier-webhook -n default-stepup \
  --from-literal=url="$WEBHOOK_URL" --dry-run=client -o yaml | kubectl apply -f -

# --- 7. Deploy the app via Radius, pointing at the ACR images ----------------
echo "Deploying StepUp via Radius..."
rad deploy infra/app.bicep \
  --parameters imageRegistry="$ACR.azurecr.io" \
  --parameters imageTag="$TAG"
kubectl wait --for=condition=ready pod -l app=postgres -n default --timeout=180s

# Restart Dapr services so sidecars reliably load their components.
for d in simulator clock notifier; do kubectl rollout restart "deploy/$d" -n default-stepup; done
for d in simulator clock notifier; do kubectl rollout status  "deploy/$d" -n default-stepup --timeout=180s; done

# --- 8. Drasi: post-install workarounds + source -> queries -> reactions ---
# drasi init above installs the control plane. Due to a pre-1.0 image tag
# mismatch (the platform release tag doesn't match GHCR image tags), several
# runtime fixes are needed. The workaround script mirrors images to ACR under
# the old project-drasi/ path and patches configs.
echo "Applying Drasi post-install workarounds..."
ACR="$ACR.azurecr.io" bash scripts/drasi-workarounds.sh

echo "Applying Drasi source..."
drasi apply -f drasi/source.yaml
echo "Waiting for source to become available..."
drasi wait -f drasi/source.yaml -t 120 2>/dev/null || true
echo "Applying Drasi queries..."
for q in behind-pace collective-progress daily-smashed new-leader race-to-goal; do
  drasi apply -f "drasi/$q.yaml"
done
echo "Applying Drasi reactions..."
for r in debug notifier-reaction; do
  drasi apply -f "drasi/$r.yaml"
done
# SignalR dashboard reaction is skipped due to upstream actor compatibility
# issues with main-branch images — it will be re-enabled once Drasi ships
# version-tagged images.
# drasi apply -f drasi/dashboard-reaction.yaml

cat <<DONE

StepUp is up on AKS ($AKS).
  Pods:       kubectl get pods -n default-stepup
  Dashboard:  kubectl port-forward -n default-stepup deploy/dashboard 9091:80
              drasi tunnel reaction dashboard 8080      # in another shell
              then open http://localhost:9091
  STOP BILLING when done:  ./scripts/aks-down.sh
DONE