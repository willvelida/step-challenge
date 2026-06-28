#!/usr/bin/env bash
set -euo pipefail

# One-time bootstrap (run by a human with Owner/UAA on the subscription):
#   1. MSI + federated creds in a dedicated RG (survives app teardown)
#   2. subscription Contributor + User Access Administrator (so the pipeline
#      can build the app infra from nothing)
#   3. writes the values GitHub Actions needs as repo VARIABLES
# AcrPush / AKS-admin are applied later by the pipeline (github-oidc-roles.bicep).
#
# Prereqs: `az login`, `gh auth login`. Edit infra/github-oidc.bicepparam first.

LOCATION=australiaeast
APP_RG=stepup-rg
ACR_NAME=stepupacr2026
AKS_NAME=stepup-aks

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

az account show >/dev/null 2>&1 || { echo "Run 'az login' first." >&2; exit 1; }
gh auth status   >/dev/null 2>&1 || { echo "Run 'gh auth login' first." >&2; exit 1; }

echo "Deploying GitHub OIDC identity (subscription scope)..."
az deployment sub create -n github-oidc -l "$LOCATION" \
  --parameters infra/github-oidc.bicepparam >/dev/null

read -r CLIENT_ID TENANT_ID SUB_ID IDENTITY_NAME IDENTITY_RG < <(
  az deployment sub show -n github-oidc --query \
    "[[properties.outputs.clientId.value, properties.outputs.tenantId.value, properties.outputs.subscriptionId.value, properties.outputs.identityName.value, properties.outputs.identityRgName.value]]" \
    -o tsv | tr -d '\r')

echo "Setting GitHub repo variables..."
gh variable set AZURE_CLIENT_ID       --body "$CLIENT_ID"
gh variable set AZURE_TENANT_ID       --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --body "$SUB_ID"
gh variable set IDENTITY_NAME         --body "$IDENTITY_NAME"
gh variable set IDENTITY_RG           --body "$IDENTITY_RG"
gh variable set APP_RG                --body "$APP_RG"
gh variable set ACR_NAME              --body "$ACR_NAME"
gh variable set AKS_NAME              --body "$AKS_NAME"
gh variable set LOCATION              --body "$LOCATION"

echo "Setting GitHub repo secrets..."
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  gh secret set DISCORD_WEBHOOK_URL --body "$DISCORD_WEBHOOK_URL"
else
  echo "  DISCORD_WEBHOOK_URL not provided — the CD workflow needs it. Either:"
  echo "    DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...' ./scripts/setup-oidc.sh"
  echo "    or:  gh secret set DISCORD_WEBHOOK_URL"
fi

echo "Done. Trigger the deploy workflow manually to build everything from scratch."