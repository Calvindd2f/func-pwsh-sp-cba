[![Docker Image CI](https://github.com/Calvindd2f/func-pwsh-sp-cba/actions/workflows/docker-image.yml/badge.svg)](https://github.com/Calvindd2f/func-pwsh-sp-cba/actions/workflows/docker-image.yml)

# SPO & PnP PowerShell - As a Multi-Tenant HTTP API

> **Run SharePoint Online PowerShell commands against any tenant, on-demand, via a simple REST API call.**
> No cold starts. No module installation waits. No per-tenant infrastructure.

---

## Why Does This Exist?

Many critical SharePoint Online administrative operations **have no REST API or Microsoft Graph equivalent**. You _must_ use PowerShell:

| Operation                       | Requires       | Graph API Available? |
| ------------------------------- | -------------- | -------------------- |
| Batch permission trimming       | SPO PowerShell | ❌ No                |
| Tenant search schema management | SPO PowerShell | ❌ No                |
| Site collection storage quotas  | SPO PowerShell | ❌ No                |
| Hub site associations           | PnP PowerShell | ⚠️ Partial           |
| Content type hub syndication    | PnP PowerShell | ❌ No                |
| Compliance / eDiscovery holds   | SPO PowerShell | ⚠️ Partial           |
| Bulk site provisioning          | PnP PowerShell | ⚠️ Partial           |
| Sharing link auditing & cleanup | PnP PowerShell | ❌ No                |

### The Problem with Running PnP/SPO PowerShell in Azure

If you try to use `PnP.PowerShell` in a standard Azure Function:

1. **Cold starts kill you** - Module installation takes 30-60 seconds on every cold start
2. **Certificate auth is complex** - Manual JWT construction, CNG vs CAPI signing, private key ACLs
3. **Multi-tenant is painful** - Each tenant needs its own auth context; no built-in session management
4. **No API surface** - You can't call PowerShell from your web apps, automation platforms (Rewst, Halo, etc.), or CI/CD pipelines

### This Solution

This project **containerizes PnP PowerShell** into an Azure Container App, with the modules **pre-baked into the Docker image**. It exposes two HTTP endpoints that accept multi-tenant credentials per-request:

```
POST /api/GenerateToken   →  Get an OAuth access token for any tenant
POST /api/InvokeScript    →  Run any PnP PowerShell script against any tenant
GET  /api/HealthCheck     →  Verify the service is running and modules are loaded
```

**Zero cold starts. Zero module installation. Multi-tenant by design.**

---

## Architecture

```
┌──────────────────┐     HTTPS      ┌─────────────────────────────┐
│  Your App /      │ ──────────────→│  Azure Container App        │
│  Automation /    │   POST JSON    │  ┌───────────────────────┐  │
│  Rewst / Halo    │   {tenantId,   │  │ Azure Functions       │  │
│                  │    clientId,   │  │ PowerShell 7.4 Worker │  │
└──────────────────┘    certBase64, │  │                       │  │
                        script}     │  │ PnP.PowerShell ✅     │  │
                                    │  │ (Pre-installed)       │  │
                                    │  └───────┬───────────────┘  │
                                    └──────────┼──────────────────┘
                                               │
                                    Connect-PnPOnline (per-request)
                                               │
                                    ┌──────────▼──────────────────┐
                                    │  SharePoint Online          │
                                    │  (Any Tenant)               │
                                    │  ┌────────┐ ┌────────┐     │
                                    │  │Tenant A│ │Tenant B│ ... │
                                    │  └────────┘ └────────┘     │
                                    └─────────────────────────────┘
```

---

## Quick Start (5 Minutes)

> **Full step-by-step guide:** [docs/QUICKSTART.md](docs/QUICKSTART.md)

### Prerequisites

- Docker installed locally
- An Entra ID App Registration with a certificate (see [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md))
- A SharePoint Online tenant URL

### 1. Clone & Build

```bash
git clone https://github.com/Calvindd2f/func-pwsh-sp-cba.git
cd func-pwsh-sp-cba
docker build -t pwsh-sp-cba .
```

### 2. Run Locally

```bash
docker run -p 8080:80 \
  -e AzureWebJobsScriptRoot=/home/site/wwwroot \
  -e TENANT_ID="your-tenant-id" \
  -e CLIENT_ID="your-client-id" \
  -e CERTIFICATE_BASE64="your-base64-pfx" \
  -e SPO_URL="https://contoso.sharepoint.com" \
  pwsh-sp-cba
```

### 3. Verify It's Running

```bash
curl http://localhost:8080/api/HealthCheck
```

### 4. Make Your First API Call

```powershell
# Generate an access token
$body = @{
    tenantId         = "your-tenant-id"
    clientId         = "your-client-id"
    certificateBase64 = "MIIJ+wIBAzCCCbg..."
    spoUrl           = "https://contoso.sharepoint.com"
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:8080/api/GenerateToken" -Method POST -Body $body -ContentType "application/json"
```

```powershell
# Run a PnP script against the tenant
$body = @{
    tenantId          = "your-tenant-id"
    clientId          = "your-client-id"
    certificateBase64 = "MIIJ+wIBAzCCCbg..."
    spoUrl            = "https://contoso.sharepoint.com"
    script            = "Get-PnPWeb | Select-Object Title, Url, Created"
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:8080/api/InvokeScript" -Method POST -Body $body -ContentType "application/json"
```

---

## API Reference

### `GET /api/HealthCheck`

Returns service status, PnP module version, and available endpoints. No authentication required.

**Response:**

```json
{
  "status": "healthy",
  "pnpModuleVersion": "2.12.0",
  "powershellVersion": "7.4.x",
  "endpoints": ["/api/GenerateToken", "/api/InvokeScript", "/api/HealthCheck"],
  "timestamp": "2025-01-15T10:30:00Z"
}
```

---

### `POST /api/GenerateToken`

Generates an OAuth 2.0 access token for SharePoint Online using Service Principal credentials. Supports both certificate-based authentication (recommended) and client secrets.

**Request Body:**

| Parameter               | Type   | Required                 | Description                                                |
| ----------------------- | ------ | ------------------------ | ---------------------------------------------------------- |
| `tenantId`              | string | Yes\*                    | Entra ID tenant ID (GUID)                                  |
| `clientId`              | string | Yes\*                    | App Registration client ID (GUID)                          |
| `spoUrl`                | string | Yes\*                    | SharePoint root URL, e.g. `https://contoso.sharepoint.com` |
| `certificateBase64`     | string | One auth method required | Base64-encoded PFX certificate                             |
| `certificatePassword`   | string | No                       | PFX password (if certificate is password-protected)        |
| `certificateThumbprint` | string | One auth method required | Thumbprint of a cert in the local cert store               |
| `clientSecret`          | string | One auth method required | Client secret string                                       |

_\*Can also be provided via environment variables (`TENANT_ID`, `CLIENT_ID`, `SPO_URL`). Request body values override environment variables._

**Success Response (200):**

```json
{
  "success": true,
  "access_token": "eyJ0eXAiOiJKV1Qi...",
  "token_type": "Bearer",
  "expires_in": 3599,
  "scope": "https://contoso.sharepoint.com/.default"
}
```

**Error Response (400/500):**

```json
{
  "error": "MISSING_REQUIRED_PARAMS",
  "message": "Missing tenantId, clientId, or spoUrl. Provide them in environment variables or request body.",
  "timestamp": "2025-01-15T10:30:00Z"
}
```

---

### `POST /api/InvokeScript`

Connects to SharePoint Online using PnP PowerShell and executes the provided script block. The PnP connection is automatically established and passed to your script as `$args[0]`.

**Request Body:**

All fields from `GenerateToken` plus:

| Parameter        | Type   | Required | Description                             |
| ---------------- | ------ | -------- | --------------------------------------- |
| `script`         | string | Yes      | PowerShell script to execute            |
| `timeoutSeconds` | int    | No       | Script execution timeout (default: 300) |

**Example - Get All Sites:**

```json
{
  "tenantId": "your-tenant-id",
  "clientId": "your-client-id",
  "certificateBase64": "MIIJ+wIBAzCCCbg...",
  "spoUrl": "https://contoso.sharepoint.com",
  "script": "Get-PnPTenantSite | Select-Object Url, Template, StorageUsageCurrent"
}
```

**Example - Batch Permission Trimming:**

```json
{
  "tenantId": "your-tenant-id",
  "clientId": "your-client-id",
  "certificateBase64": "MIIJ+wIBAzCCCbg...",
  "spoUrl": "https://contoso.sharepoint.com/sites/HR",
  "script": "Get-PnPList | ForEach-Object { Set-PnPList -Identity $_ -BreakRoleInheritance -CopyRoleAssignments }"
}
```

**Success Response (200):**

```json
{
  "success": true,
  "data": [ ... ],
  "executionTimeMs": 1234,
  "warnings": []
}
```

**Error Response (400/500):**

```json
{
  "error": "SCRIPT_EXECUTION_FAILED",
  "message": "The term 'Get-PnPFoo' is not recognized...",
  "timestamp": "2025-01-15T10:30:00Z"
}
```

---

## Real-World Use Cases

> **Full examples with copy-paste payloads:** [docs/USE-CASES.md](docs/USE-CASES.md)

| Use Case                         | Why you need PnP/SPO PowerShell                                            |
| -------------------------------- | -------------------------------------------------------------------------- |
| **Batch permission trimming**    | Remove/modify permissions across hundreds of sites - no Graph API for this |
| **Search schema management**     | Create/modify managed properties at the tenant level                       |
| **Storage quota management**     | Set per-site storage quotas (SPO admin only)                               |
| **Compliance & eDiscovery**      | Place holds, export content, manage compliance policies                    |
| **Site provisioning at scale**   | Create sites from templates with full configuration                        |
| **Sharing link audit & cleanup** | Find and remove anonymous/org-wide sharing links                           |
| **Hub site management**          | Associate/disassociate sites from hub sites                                |

---

## Authentication

> **Full authentication guide:** [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md)

This project supports three authentication methods:

| Method                       | Security  | Multi-Tenant                      | Recommended                   |
| ---------------------------- | --------- | --------------------------------- | ----------------------------- |
| **Certificate (Base64 PFX)** | ✅ High   | ✅ Yes - send per-request         | ✅ **Yes**                    |
| **Certificate (Thumbprint)** | ✅ High   | ❌ No - requires local cert store | For single-tenant             |
| **Client Secret**            | ⚠️ Medium | ✅ Yes - send per-request         | Only if certs aren't feasible |

### Quick Cert Setup

```powershell
# Run the included setup script to create an Entra ID app + cert
.\deploy\Create-EnterpriseApp.ps1
# Save the output: Client ID, Tenant ID, and Base64 PFX string
```

---

## Deployment to Azure

> **Full deployment guide:** [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)

### One-Command Deployment

```bash
# 1. Create the Entra ID App Registration (run locally)
.\deploy\Create-EnterpriseApp.ps1

# 2. Deploy infrastructure with Bicep
az deployment group create \
  --resource-group YourResourceGroup \
  --template-file deploy/main.bicep \
  --parameters clientId="CLIENT_ID" \
               tenantId="TENANT_ID" \
               spoUrl="https://contoso.sharepoint.com" \
               certificateBase64="BASE64_PFX_STRING"
```

---

## Multi-Tenant Usage (MSPs / CSPs)

> **Full multi-tenant guide:** [docs/MULTI-TENANT.md](docs/MULTI-TENANT.md)

Deploy **one instance** of this service, then pass different tenant credentials per request:

```powershell
# Tenant A
Invoke-RestMethod -Uri "$apiUrl/api/InvokeScript" -Method POST -Body (@{
    tenantId = "tenant-a-id"; clientId = "app-a-id"
    certificateBase64 = $certA; spoUrl = "https://tenantA.sharepoint.com"
    script = "Get-PnPWeb | Select Title"
} | ConvertTo-Json) -ContentType "application/json"

# Tenant B (same API, different credentials)
Invoke-RestMethod -Uri "$apiUrl/api/InvokeScript" -Method POST -Body (@{
    tenantId = "tenant-b-id"; clientId = "app-b-id"
    certificateBase64 = $certB; spoUrl = "https://tenantB.sharepoint.com"
    script = "Get-PnPWeb | Select Title"
} | ConvertTo-Json) -ContentType "application/json"
```

---

## Project Structure

```
func-pwsh-sp-cba/
├── GenerateToken/           # Azure Function: OAuth token generation
│   ├── function.json        # HTTP trigger binding (POST, GET)
│   └── run.ps1              # JWT construction + token endpoint call
├── InvokeScript/            # Azure Function: PnP script execution
│   ├── function.json        # HTTP trigger binding (POST)
│   └── run.ps1              # Connect-PnPOnline + Invoke-Command
├── HealthCheck/             # Azure Function: Service health probe
│   ├── function.json        # HTTP trigger binding (GET)
│   └── run.ps1              # Module version + status check
├── deploy/                  # Infrastructure as Code
│   ├── Create-EnterpriseApp.ps1  # Entra ID app + cert provisioning
│   └── main.bicep           # Azure Container App + Key Vault + RBAC
├── docs/                    # Documentation
│   ├── QUICKSTART.md        # Zero-to-hero in 5 minutes
│   ├── AUTHENTICATION.md    # Auth methods deep-dive
│   ├── USE-CASES.md         # Real-world script examples
│   ├── DEPLOYMENT.md        # Azure deployment guide
│   ├── MULTI-TENANT.md      # MSP/CSP patterns
│   └── TROUBLESHOOTING.md   # Common issues & fixes
├── examples/                # Client code samples
│   ├── curl-examples.sh     # cURL commands for all endpoints
│   ├── powershell-client.ps1 # PowerShell wrapper functions
│   └── common-scripts.json  # Library of useful PnP scripts
├── Dockerfile               # Multi-stage: pre-bake PnP modules
├── host.json                # Azure Functions host configuration
├── local.settings.json      # Local dev environment variables
├── .env.example             # Environment variable template
├── profile.ps1              # Worker startup script
├── requirements.psd1        # (empty - modules managed by Docker)
├── CONTRIBUTING.md          # Contribution guidelines
└── LICENSE                  # MIT License
```

---

## Troubleshooting

> **Full troubleshooting guide:** [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

| Symptom                                   | Likely Cause                                  | Fix                                                            |
| ----------------------------------------- | --------------------------------------------- | -------------------------------------------------------------- |
| `Failed to load certificate from Base64`  | Wrong password or corrupt PFX                 | Pass `certificatePassword` in request body                     |
| `Certificate does not have a private key` | Public cert (.cer) uploaded instead of PFX    | Re-export as PFX with private key                              |
| `All signing methods failed`              | Unsupported key type or container permissions | Check cert key spec - must be RSA 2048+                        |
| `Access denied` on SPO operations         | Missing admin consent                         | Run `sp-pnp-setup-prereq.ps1` or grant `Sites.FullControl.All` |
| Slow first request after deploy           | Container cold start (not module install)     | Set `minReplicas: 1` in Bicep template                         |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License - see [LICENSE](LICENSE) for details.
