# Quick Start Guide

Get from zero to your first API call in 5 minutes.

---

## Prerequisites

Before you begin, ensure you have:

| Requirement | Why | Install |
|---|---|---|
| **Docker Desktop** | Runs the containerized functions locally | [docker.com/get-docker](https://docs.docker.com/get-docker/) |
| **Azure CLI** (for deployment only) | Deploys to Azure Container Apps | [aka.ms/installazurecli](https://aka.ms/installazurecli) |
| **PowerShell 7+** | Runs the setup scripts | [aka.ms/powershell](https://aka.ms/powershell) |
| **Microsoft 365 Tenant** | The SharePoint environment you're managing | — |
| **Entra ID Admin Access** | To create the App Registration and grant consent | Global Admin or Application Admin role |

---

## Step 1: Create the Entra ID App Registration

You need an App Registration with a certificate to authenticate against SharePoint. We provide a script that does this automatically.

### Option A: Quick Setup (Recommended)

```powershell
# Install the required Graph module if you don't have it
Install-Module Microsoft.Graph.Applications -Scope CurrentUser

# Run the included setup script
.\deploy\Create-EnterpriseApp.ps1 -AppName "SPO-PowerShell-API"
```

This script will:
1. Connect you to Microsoft Graph (browser sign-in)
2. Create a multi-tenant App Registration
3. Generate a self-signed certificate
4. Upload the public key to the app
5. Output the **Client ID**, **Tenant ID**, and **Base64 PFX** string

> **⚠️ Save the output!** You'll need the `Client ID`, `Tenant ID`, and `Base64 PFX` string for the next steps.

### Option B: Advanced Setup (With Permission Scoping)

If you want more control over permissions, certificate storage, and private key ACLs:

```powershell
.\sp-pnp-setup-prereq.ps1 `
    -TenantDomain "contoso.onmicrosoft.com" `
    -AdminUPN "admin@contoso.onmicrosoft.com" `
    -AppName "SPO-PowerShell-API" `
    -AllowCertificateExport `
    -CertPassword "YourSecurePassword"
```

See [AUTHENTICATION.md](AUTHENTICATION.md) for the full details on each option.

---

## Step 2: Grant Admin Consent for SharePoint Permissions

After creating the app, you must grant it **Sites.FullControl.All** (Application) permission for SharePoint:

1. Go to the [Azure Portal](https://portal.azure.com) → **Entra ID** → **App Registrations**
2. Find your app (e.g., "SPO-PowerShell-API")
3. Go to **API Permissions** → Verify `SharePoint > Sites.FullControl.All` is listed
4. Click **Grant admin consent for [Your Org]**

> If you used `sp-pnp-setup-prereq.ps1`, admin consent is granted automatically.

---

## Step 3: Build the Docker Image

```bash
git clone https://github.com/Calvindd2f/func-pwsh-sp-cba.git
cd func-pwsh-sp-cba
docker build -t pwsh-sp-cba .
```

The multi-stage Docker build will:
1. Download `PnP.PowerShell` from PSGallery (in a temporary installer stage)
2. Copy the pre-downloaded module into the Azure Functions base image
3. Copy your function code into the image

This takes 2-5 minutes on the first build, but subsequent builds use the Docker cache.

---

## Step 4: Run Locally

### Using Docker with Environment Variables

```bash
docker run -p 8080:80 \
  -e AzureWebJobsScriptRoot=/home/site/wwwroot \
  -e TENANT_ID="your-tenant-id" \
  -e CLIENT_ID="your-client-id" \
  -e CERTIFICATE_BASE64="your-base64-pfx-string" \
  -e SPO_URL="https://contoso.sharepoint.com" \
  pwsh-sp-cba
```

### Using the `.env` file (Recommended)

```bash
# Copy the template and fill in your values
cp .env.example .env
# Edit .env with your credentials

docker run -p 8080:80 --env-file .env pwsh-sp-cba
```

---

## Step 5: Verify the Service

```bash
curl http://localhost:8080/api/HealthCheck
```

Expected response:
```json
{
  "status": "healthy",
  "pnpModuleVersion": "2.12.0",
  "powershellVersion": "7.4.x",
  "endpoints": ["/api/GenerateToken", "/api/InvokeScript", "/api/HealthCheck"]
}
```

---

## Step 6: Make Your First API Call

### Generate a Token

```bash
curl -X POST http://localhost:8080/api/GenerateToken \
  -H "Content-Type: application/json" \
  -d '{
    "tenantId": "your-tenant-id",
    "clientId": "your-client-id",
    "certificateBase64": "MIIJ+wIBAzCCCbg...",
    "spoUrl": "https://contoso.sharepoint.com"
  }'
```

### Run a PnP Script

```bash
curl -X POST http://localhost:8080/api/InvokeScript \
  -H "Content-Type: application/json" \
  -d '{
    "tenantId": "your-tenant-id",
    "clientId": "your-client-id",
    "certificateBase64": "MIIJ+wIBAzCCCbg...",
    "spoUrl": "https://contoso.sharepoint.com",
    "script": "Get-PnPWeb | Select-Object Title, Url, Created"
  }'
```

### Using PowerShell

```powershell
$params = @{
    tenantId          = "your-tenant-id"
    clientId          = "your-client-id"
    certificateBase64 = "MIIJ+wIBAzCCCbg..."
    spoUrl            = "https://contoso.sharepoint.com"
    script            = "Get-PnPWeb | Select-Object Title, Url, Created"
}

$result = Invoke-RestMethod `
    -Uri "http://localhost:8080/api/InvokeScript" `
    -Method POST `
    -Body ($params | ConvertTo-Json) `
    -ContentType "application/json"

$result
```

---

## Next Steps

- **Deploy to Azure**: See [DEPLOYMENT.md](DEPLOYMENT.md) for Azure Container Apps deployment
- **Multi-tenant setup**: See [MULTI-TENANT.md](MULTI-TENANT.md) for MSP/CSP patterns
- **Real-world scripts**: See [USE-CASES.md](USE-CASES.md) for batch permission trimming, compliance, and more
- **Troubleshooting**: See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if anything goes wrong
