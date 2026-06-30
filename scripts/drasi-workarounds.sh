#!/usr/bin/env bash
# Drasi post-install workarounds for pre-1.0 GHCR image tag incompatibilities.
#
# The drasi-platform 0.10.0 release tags its GitHub release as "Pre-release"
# but the container images on ghcr.io/drasi-project/ do not carry matching
# version tags — only 'main' (from the default branch) and commit SHAs.
# Furthermore the Drasi resource provider hardcodes 'project-drasi' as the
# image org prefix, but images now live under 'drasi-project'.
#
# This script mirrors the needed images into the project ACR under the old
# 'project-drasi/' path and applies the runtime fixes that make the main-branch
# images work together.
#
# Run this AFTER `drasi init` completes (or partially completes) and BEFORE
# applying Drasi source/queries/reactions.
#
# Prerequisites: az, kubectl, drasi CLIs on PATH, ACR name below.
# ============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---- config (set these before running) ------------------------------------
ACR="${ACR:-}"                     # e.g. stepupacrxxxx.azurecr.io (no protocol)
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

# shellcheck disable=SC2317
usage() {
  echo "Usage: ACR=myacr.azurecr.io [DISCORD_WEBHOOK_URL=...] $0"
  exit 1
}
[ -n "$ACR" ] || usage

echo "=== Step 1: Mirror Drasi images to ACR under project-drasi/ path ==="
# The resource provider resolves images as ${ACR}/project-drasi/${image}:${tag}
# We mirror from ghcr.io/drasi-project/ to ${ACR}/project-drasi/ with tags
# that match the ConfigMap IMAGE_VERSION_TAG (default: main).
#
# Images needed by the StepUp solution:
IMAGES_TO_IMPORT=(
  "query-container-query-host:main"
  "query-container-publish-api:main"
  "query-container-view-svc:main"
  "source-sql-proxy:main"
  "source-debezium-reactivator:main"
  "source-change-dispatcher:main"
  "source-change-svc:main"
  "source-query-api:main"
  "reaction-signalr:main"
  "reaction-post-dapr-pubsub:0.4.0"
  "reaction-debug:d89922d64ec9f5ef3196806f90cbaefbe8cee409"
)

for img in "${IMAGES_TO_IMPORT[@]}"; do
  name="${img%%:*}"
  tag="${img#*:}"
  # Tag on ACR is always 'main' so it matches IMAGE_VERSION_TAG in the ConfigMap
  echo "  Importing ghcr.io/drasi-project/${name}:${tag} → ${ACR}/project-drasi/${name}:main"
  az acr import -n "${ACR%.azurecr.io}" \
    --source "ghcr.io/drasi-project/${name}:${tag}" \
    --image "project-drasi/${name}:main" 2>&1 | tail -1
done

echo ""
echo "=== Step 2: Patch ACR config in drasi-system ConfigMap ==="
kubectl patch configmap drasi-config -n drasi-system \
  -p "{\"data\":{\"ACR\":\"${ACR}\",\"IMAGE_VERSION_TAG\":\"main\",\"IMAGE_PULL_POLICY\":\"IfNotPresent\"}}"

echo ""
echo "=== Step 3: Fix Dapr pubsub components (rg-redis → actual Redis) ==="
for comp in rg-pubsub-debug rg-pubsub-notifier rg-pubsub-dashboard; do
  if kubectl get component "$comp" -n drasi-system &>/dev/null; then
    kubectl patch component "$comp" -n drasi-system --type json \
      -p '[{"op":"replace","path":"/spec/metadata/0","value":{"name":"redisHost","value":"drasi-redis:6379"}}]'
  fi
done

echo ""
echo "=== Step 4: Create rg-state Dapr component (needed by source change-svc + reactivator) ==="
# Default Drasi Redis lacks RedisJSON module, so the change-svc state query fails.
# Switch to MongoDB which supports the Dapr state query API.
kubectl delete component rg-state -n drasi-system 2>/dev/null || true
kubectl apply -n drasi-system -f - <<YAML
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: rg-state
spec:
  type: state.mongodb
  version: v1
  metadata:
    - name: host
      value: drasi-mongo:27017
    - name: databaseName
      value: Drasi
    - name: collectionName
      value: rg-state
YAML

echo ""
echo "=== Step 5a: Fix query-host REDIS_BROKER (workers need it for change stream) ==="
kubectl set env deployment/default-query-host -n drasi-system \
  REDIS_BROKER="redis://10.0.126.12:6379"

echo ""
echo "=== Step 5b: Fix publish-api REDIS_BROKER (DNS resolution in distroless image) ==="
kubectl set env deployment/default-publish-api -n drasi-system \
  REDIS_BROKER="redis://drasi-redis.drasi-system.svc.cluster.local:6379"

echo ""
echo "=== Step 6: Fix source proxy (client=pg for knex) ==="
kubectl set env deployment/stepup-proxy -n drasi-system client=pg

echo ""
echo "=== Step 7: Register minimal SignalR provider (avoids actor config crash) ==="
# The full SignalR provider definition from drasi init's manifest includes
# endpoints and config_schema that trigger an actor configuration call on
# the query-host, which crashes in main-branch builds. A minimal provider
# (image only) registers cleanly.
cat > /tmp/signalr-provider.yaml << 'EOF'
kind: ReactionProvider
apiVersion: v1
name: SignalR
spec:
  services:
    reaction:
      image: reaction-signalr
EOF
kubectl delete reactionprovider SignalR -n drasi-system 2>/dev/null || true
drasi apply -f /tmp/signalr-provider.yaml

echo ""
echo "=== Step 8: Fix reactivator Dapr config (gRPC protocol + no app-port) ==="
# The reactivator is a gRPC client only — it doesn't serve HTTP or gRPC, so
# app-port must be removed to prevent Dapr sidecar from waiting for it.
kubectl patch deployment stepup-reactivator -n drasi-system --type json \
  -p '[{"op":"add","path":"/spec/template/metadata/annotations/dapr.io~1app-protocol","value":"grpc"},{"op":"remove","path":"/spec/template/metadata/annotations/dapr.io~1app-port"}]'

echo ""
echo "=== Step 8: Restart affected pods ==="
kubectl rollout restart deployment \
  -n drasi-system \
  default-publish-api \
  stepup-proxy \
  stepup-reactivator \
  stepup-change-svc \
  stepup-change-dispatcher \
  stepup-query-api

echo ""
echo "=== Step 9: Expose dashboard via LoadBalancer ==="
kubectl patch svc dashboard -n default-stepup -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true

echo ""
echo "=== Step 10: Apply dashboard reaction (SignalR) ==="
drasi apply -f drasi/dashboard-reaction.yaml 2>/dev/null || true

echo ""
echo "=== Step 11: Wait for pods to stabilise ==="
sleep 15
kubectl wait --for=condition=ready pod -n drasi-system \
  -l drasi/infra=api --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=ready pod -n drasi-system \
  -l app=drasi-resource-provider --timeout=60s 2>/dev/null || true

echo ""
echo "Done. Check progress with:"
echo "  drasi list source"
echo "  drasi list query"
echo "  drasi list reaction"
echo "  kubectl get pods -n drasi-system"
