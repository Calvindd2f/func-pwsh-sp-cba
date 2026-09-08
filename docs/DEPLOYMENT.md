# Deployment Guide

Step-by-step guide to deploying the SPO PowerShell API to Azure Container Apps.

---

## Architecture Overview

```
Azure Resource Group
├── Container App Environment
│   └── Container App (your API)
│       ├── Docker image with PnP.PowerShell pre-installed
│       ├── Azure Functions PowerShell 7.4 worker
│       └── System-assigned Managed Identity
├── Key Vault
│   ├── Certificate (Base64 PFX) stored as secret
│   └── RBAC: Container App → Key Vault Secrets User
└── Log Analytics Workspace
    └── Container App logs
```

### What Gets Deployed

| Resource | SKU / Tier | Estimated Cost |
|---|---|---|
| Container App Environment | Consumption (serverless) | Free (included compute) |
| Container App | 0.5 vCPU, 1 GB RAM | ~$0/month at low usage (pay-per-request) |
| Key Vault | Standard | ~$0.03/10K operations |
| Log Analytics Workspace | Pay-as-you-go, 30-day retention | ~$2.76/GB ingested |

> **Total estimated cost**: Near-zero for low to moderate usage. The Container Apps consumption plan scales to zero when idle.

---

## Prerequisites

| Requirement | Purpose |
|---|---|
| Azure subscription | Hosts the Container App |
| Azure CLI (`az`) | Deploys Bicep templates |
| Docker | Builds the container image |
| PowerShell 7+ | Runs the Entra ID setup scripts |
| `Microsoft.Graph.Applications` module | Creates the App Registration |
| Azure Container Registry (ACR) or Docker Hub | Hosts your container image |

---

## Step 1: Create the Entra ID App Registration

```powershell
# Run the included script
.\deploy\Create-EnterpriseApp.ps1 -AppName "SPO-PowerShell-API"
```

**Save the output:**
- `Client ID` (GUID)
- `Tenant ID` (GUID)
- `Base64 PFX` (long Base64 string)

> See [AUTHENTICATION.md](AUTHENTICATION.md) for alternative setup methods.

---

## Step 2: Build and Push the Docker Image

### Option A: Azure Container Registry (Recommended)

```bash
# Create an ACR (one-time)
az acr create --resource-group YourResourceGroup --name yourregistry --sku Basic

# Build and push
az acr build --registry yourregistry --image pwsh-sp-cba:latest .
```

### Option B: Docker Hub

```bash
docker build -t yourusername/pwsh-sp-cba:latest .
docker push yourusername/pwsh-sp-cba:latest
```

---

## Step 3: Deploy Azure Resources with Bicep

The included Bicep template deploys everything you need: Container App, Key Vault, Log Analytics, and RBAC.

### Basic Deployment

```bash
# Login to Azure
az login

# Create a resource group (if you don't have one)
az group create --name rg-spo-pwsh-api --location eastus

# Deploy
az deployment group create \
  --resource-group rg-spo-pwsh-api \
  --template-file deploy/main.bicep \
  --parameters \
    clientId="YOUR_CLIENT_ID" \
    tenantId="YOUR_TENANT_ID" \
    spoUrl="https://contoso.sharepoint.com" \
    certificateBase64="YOUR_BASE64_PFX_STRING" \
    containerImage="yourregistry.azurecr.io/pwsh-sp-cba:latest"
```

### With Custom App Name

```bash
az deployment group create \
  --resource-group rg-spo-pwsh-api \
  --template-file deploy/main.bicep \
  --parameters \
    appName="myspoapi" \
    clientId="YOUR_CLIENT_ID" \
    tenantId="YOUR_TENANT_ID" \
    spoUrl="https://contoso.sharepoint.com" \
    certificateBase64="YOUR_BASE64_PFX_STRING" \
    containerImage="yourregistry.azurecr.io/pwsh-sp-cba:latest"
```

### Deployment Output

The Bicep template outputs:
- `containerAppFqdn` — Your API's public URL (e.g., `myspoapi-app.azurecontainerapps.io`)
- `keyVaultName` — The Key Vault storing your certificate

---

## Step 4: Verify the Deployment

```bash
# Get the FQDN from the deployment output
FQDN=$(az deployment group show \
  --resource-group rg-spo-pwsh-api \
  --name main \
  --query properties.outputs.containerAppFqdn.value -o tsv)

# Test the health endpoint
curl "https://$FQDN/api/HealthCheck"
```

---

## Step 5: Get Your Function Key

Azure Functions uses function keys for authorization. To call the API endpoints, you need the function key:

```bash
# The function key is auto-generated. You can find it in the Azure Portal:
# Container App → Functions → GenerateToken → Function Keys → default
```

Then include it in your API calls:

```bash
curl "https://your-app.azurecontainerapps.io/api/HealthCheck?code=YOUR_FUNCTION_KEY"
```

---

## Security Hardening Checklist

After deployment, review these security settings:

- [ ] **HTTPS only**: Container Apps enforce HTTPS by default (`allowInsecure: false` in Bicep)
- [ ] **Function keys**: Both `GenerateToken` and `InvokeScript` require function-level auth
- [ ] **Key Vault RBAC**: Managed Identity has `Key Vault Secrets User` role (read-only)
- [ ] **No secrets in env vars**: Certificate is stored in Key Vault, referenced via secret binding
- [ ] **Log Analytics**: All logs are sent to a dedicated workspace
- [ ] **Scale limits**: Default max 5 replicas — adjust in Bicep if needed
- [ ] **Network restrictions**: Consider adding IP allow-listing via Container App ingress rules

### Optional: Add IP Restrictions

In the Bicep template, add to the ingress configuration:

```bicep
ingress: {
  external: true
  targetPort: 80
  allowInsecure: false
  ipSecurityRestrictions: [
    {
      name: 'allow-office'
      ipAddressRange: '203.0.113.0/24'
      action: 'Allow'
    }
  ]
}
```

---

## Monitoring & Logging

### View Container Logs

```bash
az containerapp logs show \
  --name pwshspcba-app \
  --resource-group rg-spo-pwsh-api \
  --follow
```

### Query Log Analytics

```kusto
// Find all failed script executions
ContainerAppConsoleLogs_CL
| where Log_s contains "Script execution failed"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

### Add Application Insights (Optional)

For more detailed telemetry, add an Application Insights connection string to the container:

```bash
az containerapp update \
  --name pwshspcba-app \
  --resource-group rg-spo-pwsh-api \
  --set-env-vars "APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=..."
```

---

## Updating the Deployment

### Update the Container Image

```bash
# Build and push a new image
az acr build --registry yourregistry --image pwsh-sp-cba:v2 .

# Update the Container App
az containerapp update \
  --name pwshspcba-app \
  --resource-group rg-spo-pwsh-api \
  --image yourregistry.azurecr.io/pwsh-sp-cba:v2
```

### Update Environment Variables

```bash
az containerapp update \
  --name pwshspcba-app \
  --resource-group rg-spo-pwsh-api \
  --set-env-vars "SPO_URL=https://newtenant.sharepoint.com"
```

---

## Scaling Configuration

The default Bicep template sets:
- **Min replicas**: 0 (scales to zero when idle)
- **Max replicas**: 5

### Always-On (No Cold Starts)

Set `minReplicas: 1` in the Bicep template to keep at least one instance running:

```bicep
scale: {
  minReplicas: 1  // Changed from 0
  maxReplicas: 5
}
```

> **Cost impact**: ~$10-15/month for the always-on instance.
