#!/usr/bin/env bash
set -euo pipefail

# Configure the Radius 'default' environment for StepUp: ensure the group + env
# exist, register the portable-resource Recipes, and (on Azure) point the Azure
# provider at the app resource group. Idempotent; safe to re-run on every spin-up.
#
# Optional env vars for the Azure provider scope (set on AKS, unset locally):
#   AZ_SUB  Azure subscription id
#   AZ_RG   Azure resource group where Azure-native recipes will deploy
#
# Recipes come from the public Radius local-dev pack (container-based, work on
# both kind and AKS), so no OCI publishing is needed yet. Override with:
#   RECIPE_PREFIX (default ghcr.io/radius-project/recipes/local-dev)
#   RECIPE_TAG    (default latest)

GROUP=default
ENV=default
NS=default
RECIPE_PREFIX="${RECIPE_PREFIX:-ghcr.io/radius-project/recipes/local-dev}"
RECIPE_TAG="${RECIPE_TAG:-latest}"

# 1. Ensure the Radius resource group + environment exist (idempotent).
rad group show "$GROUP" >/dev/null 2>&1 || rad group create "$GROUP"
rad env show "$ENV" --group "$GROUP" >/dev/null 2>&1 \
  || rad env create "$ENV" --group "$GROUP" --namespace "$NS"

# 2. Register the portable-resource Recipes (PR1: Redis only). Re-running
#    overwrites the recipe, so this is safe on every spin-up.
rad recipe register default \
  --environment "$ENV" --group "$GROUP" \
  --resource-type Applications.Datastores/redisCaches \
  --template-kind bicep \
  --template-path "$RECIPE_PREFIX/rediscaches:$RECIPE_TAG"

# 3. On Azure, give the environment a provider scope so Azure-native recipes
#    (later PRs) have somewhere to deploy. Skipped locally.
if [ -n "${AZ_SUB:-}" ] && [ -n "${AZ_RG:-}" ]; then
  rad env update "$ENV" --group "$GROUP" \
    --azure-subscription-id "$AZ_SUB" \
    --azure-resource-group "$AZ_RG"
fi

echo "Radius environment '$ENV' configured. Recipes:"
rad recipe list --environment "$ENV" --group "$GROUP"