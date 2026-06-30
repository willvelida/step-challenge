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
echo "=== Step 4: Create rg-state + rg-pubsub Dapr components ==="
# rg-state: change-svc needs state query API which requires RedisJSON on Redis.
# Standard Redis doesn't have it. Switch to MongoDB.
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
---
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: rg-pubsub
spec:
  type: pubsub.redis
  version: v1
  metadata:
    - name: redisHost
      value: drasi-redis:6379
    - name: redisPassword
      value: ""
---
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: stepup-pubsub
spec:
  type: pubsub.redis
  version: v1
  metadata:
    - name: redisHost
      value: redis.default.svc.cluster.local:6379
    - name: redisPassword
      value: ""
YAML

echo ""
echo "=== Step 5: Fix publish-api + query-host REDIS_BROKER (distroless DNS) ==="
kubectl set env deployment/default-publish-api -n drasi-system \
  REDIS_BROKER="redis://drasi-redis.drasi-system.svc.cluster.local:6379"
kubectl set env deployment/default-query-host -n drasi-system \
  REDIS_BROKER="redis://drasi-redis.drasi-system.svc.cluster.local:6379"

echo ""
echo "=== Step 6: Fix source proxy + reactivator env ==="
PROXY_DEPLOY=$(kubectl get deploy -n drasi-system -l 'drasi/type=source,drasi/service=proxy' -o name 2>/dev/null | head -1)
[ -n "$PROXY_DEPLOY" ] && kubectl set env "$PROXY_DEPLOY" -n drasi-system client=pg
REACTIVATOR_DEPLOY=$(kubectl get deploy -n drasi-system -l 'drasi/type=source,drasi/service=reactivator' -o name 2>/dev/null | head -1)
[ -n "$REACTIVATOR_DEPLOY" ] && kubectl set env "$REACTIVATOR_DEPLOY" -n drasi-system PUBSUB=rg-pubsub

echo ""
echo "=== Step 7: Fix reactivator Dapr config (client-only gRPC) ==="
REACTIVATOR_DEPLOY=$(kubectl get deploy -n drasi-system -l 'drasi/type=source,drasi/service=reactivator' -o name 2>/dev/null | head -1)
if [ -n "$REACTIVATOR_DEPLOY" ]; then
  kubectl patch "$REACTIVATOR_DEPLOY" -n drasi-system --type json \
    -p '[{"op":"add","path":"/spec/template/metadata/annotations/dapr.io~1app-protocol","value":"grpc"},{"op":"remove","path":"/spec/template/metadata/annotations/dapr.io~1app-port"}]' 2>/dev/null || true
fi

echo ""
echo "=== Step 8: Register minimal SignalR provider ==="
cat > /tmp/signalr-provider.yaml << 'EOF'
kind: ReactionProvider
apiVersion: v1
name: SignalR
spec:
  services:
    reaction:
      image: reaction-signalr
EOF
drasi delete reactionprovider SignalR -n drasi-system 2>/dev/null || true
drasi apply -f /tmp/signalr-provider.yaml

echo ""
echo "=== Step 9: Restart affected deployments ==="
kubectl rollout restart deployment -n drasi-system \
  default-publish-api default-query-host 2>/dev/null || true
kubectl rollout restart deployment -n drasi-system \
  -l 'drasi/type=source' 2>/dev/null || true

echo ""
echo "=== Step 10: Wait for pods to stabilise ==="
sleep 15
kubectl wait --for=condition=ready pod -n drasi-system \
  -l drasi/infra=api --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=ready pod -n drasi-system \
  -l app=drasi-resource-provider --timeout=60s 2>/dev/null || true

echo ""
echo "=== Step 11: Expose dashboard via LoadBalancer ==="
kubectl patch svc dashboard -n default-stepup -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true

echo ""
echo "Done. Next steps (run manually after source is available):"
echo "  drasi apply -f drasi/source.yaml && drasi wait source stepup 120"
echo "  drasi apply -f drasi/race-to-goal.yaml ... (all 5 queries)"
echo "  drasi apply -f drasi/debug.yaml drasi/notifier-reaction.yaml drasi/dashboard-reaction.yaml"
echo "  kubectl rollout restart deployment/notifier-reaction -n drasi-system"
