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
# The fixes must interleave with `drasi apply`, because the resource provider
# only creates the source/reaction workers when those objects are applied. The
# script therefore runs in phases, called at three points from aks-up.sh:
#
#   pre        after `drasi init`, before any `drasi apply`
#              (mirror images, patch config, create components, query-host env,
#               SignalR provider, expose dashboard)
#   source     after `drasi apply -f source.yaml`, BEFORE `drasi wait`
#              (patch the proxy + reactivator so the source can reach AVAILABLE)
#   reactions  after the reactions are applied
#              (point the reaction pubsub components at the real Redis)
#
# Usage:  ACR=myacr.azurecr.io scripts/drasi-workarounds.sh [pre|source|reactions|all]
#
# Prerequisites: az, kubectl, drasi CLIs on PATH.
# ============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NS=drasi-system
PHASE="${1:-all}"

# ---- config ---------------------------------------------------------------
ACR="${ACR:-}"                     # e.g. stepupacrxxxx.azurecr.io (no protocol)

usage() {
  echo "Usage: ACR=myacr.azurecr.io $0 [pre|source|reactions|all]" >&2
  exit 1
}

# ---- helpers --------------------------------------------------------------

# Detect the component-name prefix this Drasi build uses (drasi-* vs rg-*).
detect_prefix() {
  DRASI_COMPONENT_PREFIX=drasi
  if   kubectl get component drasi-pubsub -n "$NS" >/dev/null 2>&1 || \
       kubectl get component drasi-state  -n "$NS" >/dev/null 2>&1; then
    DRASI_COMPONENT_PREFIX=drasi
  elif kubectl get component rg-pubsub    -n "$NS" >/dev/null 2>&1 || \
       kubectl get component rg-state     -n "$NS" >/dev/null 2>&1; then
    DRASI_COMPONENT_PREFIX=rg
  fi
  echo "Component prefix: ${DRASI_COMPONENT_PREFIX}"
}

# Wait (~60s) for a deployment matching a label selector; echo its name on success.
wait_for_deploy_selector() {
  local sel="$1" i name
  for i in $(seq 1 30); do
    name="$(kubectl get deploy -n "$NS" -l "$sel" -o name 2>/dev/null | head -1)"
    [ -n "$name" ] && { echo "$name"; return 0; }
    sleep 2
  done
  return 1
}

# Wait (~60s) for a named deployment to exist.
wait_for_deploy_name() {
  local name="$1" i
  for i in $(seq 1 30); do
    kubectl get deploy "$name" -n "$NS" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Wait (~60s) for a named Dapr component to exist.
wait_for_component() {
  local name="$1" i
  for i in $(seq 1 30); do
    kubectl get component "$name" -n "$NS" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# ---- phase: pre -----------------------------------------------------------
# After `drasi init`, before any `drasi apply`.
phase_pre() {
  [ -n "$ACR" ] || usage
  detect_prefix

  echo "=== [pre] Mirror Drasi images to ACR under project-drasi/ path ==="
  # The resource provider resolves images as ${ACR}/project-drasi/${image}:main.
  local IMAGES_TO_IMPORT=(
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
  local img name tag
  for img in "${IMAGES_TO_IMPORT[@]}"; do
    name="${img%%:*}"
    tag="${img#*:}"
    echo "  Importing ghcr.io/drasi-project/${name}:${tag} → ${ACR}/project-drasi/${name}:main"
    az acr import -n "${ACR%.azurecr.io}" \
      --source "ghcr.io/drasi-project/${name}:${tag}" \
      --image "project-drasi/${name}:main" --force 2>&1 | tail -1
  done

  echo ""
  echo "=== [pre] Patch ACR config in drasi-system ConfigMap ==="
  kubectl patch configmap drasi-config -n "$NS" \
    -p "{\"data\":{\"ACR\":\"${ACR}\",\"IMAGE_VERSION_TAG\":\"main\",\"IMAGE_PULL_POLICY\":\"IfNotPresent\"}}"

  echo ""
  echo "=== [pre] Create ${DRASI_COMPONENT_PREFIX}-state + ${DRASI_COMPONENT_PREFIX}-pubsub + stepup-pubsub ==="
  # change-svc needs the Dapr state query API, which needs RedisJSON. Stock Redis
  # lacks it, so back the state store with MongoDB instead.
  kubectl delete component "${DRASI_COMPONENT_PREFIX}-state" -n "$NS" 2>/dev/null || true
  kubectl apply -n "$NS" -f - <<YAML
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: ${DRASI_COMPONENT_PREFIX}-state
spec:
  type: state.mongodb
  version: v1
  metadata:
    - name: host
      value: drasi-mongo:27017
    - name: databaseName
      value: Drasi
    - name: collectionName
      value: ${DRASI_COMPONENT_PREFIX}-state
---
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: ${DRASI_COMPONENT_PREFIX}-pubsub
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
  echo "=== [pre] Set REDIS_BROKER on publish-api + query-host (distroless DNS) ==="
  local d
  for d in default-publish-api default-query-host; do
    wait_for_deploy_name "$d" || { echo "$d not created yet; is the query container up?" >&2; exit 1; }
    kubectl set env "deployment/$d" -n "$NS" \
      REDIS_BROKER="redis://drasi-redis.drasi-system.svc.cluster.local:6379"
  done

  echo ""
  echo "=== [pre] Register minimal SignalR provider ==="
  cat > /tmp/signalr-provider.yaml << 'EOF'
kind: ReactionProvider
apiVersion: v1
name: SignalR
spec:
  services:
    reaction:
      image: reaction-signalr
EOF
  drasi delete reactionprovider SignalR -n "$NS" 2>/dev/null || true
  drasi apply -f /tmp/signalr-provider.yaml

  echo ""
  echo "=== [pre] Restart control-plane deployments + wait ==="
  kubectl rollout restart deployment -n "$NS" \
    default-publish-api default-query-host 2>/dev/null || true
  sleep 15
  kubectl wait --for=condition=ready pod -n "$NS" \
    -l drasi/infra=api --timeout=60s 2>/dev/null || true
  kubectl wait --for=condition=ready pod -n "$NS" \
    -l app=drasi-resource-provider --timeout=60s 2>/dev/null || true

  echo ""
  echo "=== [pre] Expose dashboard via LoadBalancer ==="
  kubectl patch svc dashboard -n default-stepup \
    -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true
}

# ---- phase: source --------------------------------------------------------
# After `drasi apply -f source.yaml`, BEFORE `drasi wait`. The reactivator ships
# with dapr.io/app-port set, which deadlocks its (client-only) sidecar and keeps
# the source from ever reaching AVAILABLE — so it must be patched before the
# wait, not after.
phase_source() {
  detect_prefix
  echo "=== [source] Patch source proxy + reactivator ==="
  local PROXY_DEPLOY REACTIVATOR_DEPLOY
  PROXY_DEPLOY="$(wait_for_deploy_selector 'drasi/type=source,drasi/service=proxy' || true)"
  REACTIVATOR_DEPLOY="$(wait_for_deploy_selector 'drasi/type=source,drasi/service=reactivator' || true)"

  if [ -n "$PROXY_DEPLOY" ]; then
    kubectl set env "$PROXY_DEPLOY" -n "$NS" client=pg
  else
    echo "  proxy deployment not found; skipping." >&2
  fi

  if [ -n "$REACTIVATOR_DEPLOY" ]; then
    kubectl set env "$REACTIVATOR_DEPLOY" -n "$NS" PUBSUB="${DRASI_COMPONENT_PREFIX}-pubsub"
    kubectl patch "$REACTIVATOR_DEPLOY" -n "$NS" --type json \
      -p '[{"op":"add","path":"/spec/template/metadata/annotations/dapr.io~1app-protocol","value":"grpc"},{"op":"remove","path":"/spec/template/metadata/annotations/dapr.io~1app-port"}]' 2>/dev/null || true
  else
    echo "  reactivator deployment not found; skipping." >&2
  fi
}

# ---- phase: reactions -----------------------------------------------------
# After the reactions are applied. The reaction pubsub components are created
# with the reactions, so this runs last; patching a Dapr component doesn't
# restart the pod, so bounce the reactions to reload it.
phase_reactions() {
  detect_prefix
  echo "=== [reactions] Point reaction pubsub components at drasi-redis ==="
  local comp
  for comp in "${DRASI_COMPONENT_PREFIX}"-pubsub-debug \
              "${DRASI_COMPONENT_PREFIX}"-pubsub-notifier \
              "${DRASI_COMPONENT_PREFIX}"-pubsub-dashboard; do
    if wait_for_component "$comp"; then
      kubectl patch component "$comp" -n "$NS" --type json \
        -p '[{"op":"replace","path":"/spec/metadata/0","value":{"name":"redisHost","value":"drasi-redis:6379"}}]'
    else
      echo "  component $comp not found; skipping." >&2
    fi
  done

  echo ""
  echo "=== [reactions] Restart reactions so sidecars reload the patched component ==="
  kubectl rollout restart deployment -n "$NS" -l 'drasi/type=reaction' 2>/dev/null || true
}

# ---- dispatch -------------------------------------------------------------
case "$PHASE" in
  pre)       phase_pre ;;
  source)    phase_source ;;
  reactions) phase_reactions ;;
  all)       phase_pre; phase_source; phase_reactions ;;
  *) echo "Unknown phase: $PHASE" >&2; usage ;;
esac

echo ""
echo "Done (phase: $PHASE)."
