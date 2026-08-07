#!/usr/bin/env bash
# Netra one-line installer — run in Azure Cloud Shell (Bash):
#   curl -sL https://netra.run/install.sh | bash -s -- --region australiaeast
#
# Deploys Netra (read-only Azure ISM PROTECTED reporter) into the current
# subscription as a single Container App with a user-assigned managed identity,
# grants it the Reader role, and registers an Entra app for sign-in. The
# read-only Microsoft Graph permission (Policy.Read.All) for identity checks is
# consented afterwards from the app's own "Permissions to grant" panel.
set -euo pipefail

REGION="australiaeast"
RG="rg-netra"
STACK="netra"
IMAGE="ghcr.io/abhijitsghosh/netra:latest"
BASE="${NETRA_BASE:-https://raw.githubusercontent.com/abhijitsghosh/netra-deploy/main}"
TEMPLATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --resource-group) RG="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --template-file) TEMPLATE="$2"; shift 2;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done

echo "==> Netra install into region '$REGION', resource group '$RG'"
TENANT=$(az account show --query tenantId -o tsv)
SUB=$(az account show --query id -o tsv)

# [1/3] Entra app registration (confidential OIDC client), idempotent by name.
echo "==> [1/3] Entra app registration"
APP_ID=$(az ad app list --display-name Netra --query "[0].appId" -o tsv)
if [[ -z "$APP_ID" ]]; then
  APP_ID=$(az ad app create --display-name Netra --sign-in-audience AzureADMyOrg \
    --web-redirect-uris "https://localhost/login/oauth2/code/entra" --query appId -o tsv)
fi
az ad sp create --id "$APP_ID" >/dev/null 2>&1 || true
# Secrets can't be read back, so mint a fresh one each install.
SECRET=$(az ad app credential reset --id "$APP_ID" --display-name netra-install --query password -o tsv)

# [2/3] Deploy the resource-group-scoped stack.
echo "==> [2/3] Deploy Container App stack"
az group create -n "$RG" -l "$REGION" -o none
if [[ -z "$TEMPLATE" ]]; then
  TEMPLATE="$(mktemp).json"
  curl -sL "$BASE/azuredeploy.json" -o "$TEMPLATE"
fi
# Generate a strong Postgres admin password (only used inside this deployment; stored as a
# Container App secret and passed to the managed database). Reuse an existing one on re-run so an
# upgrade keeps the same database — attestations and decisions are preserved across upgrades.
DB_PASSWORD="${NETRA_DB_PASSWORD:-}"
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD=$(az containerapp secret show -g "$RG" -n "${STACK}-app" --secret-name db-password \
    --query value -o tsv 2>/dev/null || true)
fi
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="Nt$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 22)9!"

az stack group create --name "$STACK" --resource-group "$RG" \
  --template-file "$TEMPLATE" \
  --parameters entraTenantId="$TENANT" entraClientId="$APP_ID" entraClientSecret="$SECRET" image="$IMAGE" \
    dbAdminPassword="$DB_PASSWORD" \
  --action-on-unmanage deleteAll --deny-settings-mode none --yes -o none

APP_URL=$(az deployment group show -g "$RG" -n "$STACK" --query "properties.outputs.appUrl.value" -o tsv 2>/dev/null || \
          az containerapp show -g "$RG" -n "${STACK}-app" --query "properties.configuration.ingress.fqdn" -o tsv | sed 's,^,https://,')
MI_OBJ=$(az identity show -g "$RG" -n "${STACK}-mi" --query principalId -o tsv)

# [3/3] Patch the real redirect URI and grant Reader on the subscription.
echo "==> [3/3] Finalise sign-in + grant Reader"
az ad app update --id "$APP_ID" --web-redirect-uris "$APP_URL/login/oauth2/code/entra"
if az role assignment create --assignee-object-id "$MI_OBJ" --assignee-principal-type ServicePrincipal \
     --role Reader --scope "/subscriptions/$SUB" -o none 2>/dev/null; then
  echo "    Reader granted on subscription $SUB"
else
  echo "    NOTE: could not grant Reader (needs Owner/User Access Administrator). An admin should run:"
  echo "    az role assignment create --assignee-object-id $MI_OBJ --assignee-principal-type ServicePrincipal --role Reader --scope /subscriptions/$SUB"
fi

# Restart so the app picks up the patched redirect URI.
az containerapp revision restart -g "$RG" -n "${STACK}-app" \
  --revision "$(az containerapp show -g "$RG" -n "${STACK}-app" --query 'properties.latestRevisionName' -o tsv)" -o none 2>/dev/null || true

cat <<EOF

==> Netra is deployed.
    URL:            $APP_URL
    Reader role:    granted on subscription $SUB (base ISM + hardening checks work now)
    Identity plane: open the app, run a scan, then use the "Permissions to grant"
                    panel to consent to the read-only Policy.Read.All Graph permission
                    (one-click portal link or the az CLI command shown there).

    Teardown: az stack group delete --name $STACK -g $RG --action-on-unmanage deleteAll --yes \\
              && az group delete -n $RG --yes \\
              && az role assignment delete --assignee "$MI_OBJ" --role Reader --scope /subscriptions/$SUB \\
              && az ad app delete --id $APP_ID
EOF
