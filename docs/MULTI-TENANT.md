# Multi-Tenant Usage Guide

This guide covers how MSPs (Managed Service Providers), CSPs (Cloud Solution Providers), and multi-tenant organizations can use a **single deployment** of the SPO PowerShell API to manage **multiple Microsoft 365 tenants**.

---

## How Multi-Tenancy Works

The API is stateless — every request includes all the credentials needed to connect to a specific tenant. There's no session, no stored state, no tenant configuration on the server. You deploy **one instance** and pass different credentials per request.

```
                           ┌─────────────────────┐
  Tenant A credentials ──→ │                     │ ──→ Tenant A SharePoint
  Tenant B credentials ──→ │   Single API        │ ──→ Tenant B SharePoint
  Tenant C credentials ──→ │   Instance          │ ──→ Tenant C SharePoint
  Tenant D credentials ──→ │                     │ ──→ Tenant D SharePoint
                           └─────────────────────┘
```

### What You Need Per Tenant

For each tenant you want to manage, you need:

1. **An App Registration** (multi-tenant) registered in that tenant with admin consent
2. **A certificate** (PFX) whose public key is uploaded to the App Registration
3. The **Tenant ID**, **Client ID**, and **SPO URL** for that tenant

---

## Setup Pattern: One Multi-Tenant App Registration

Instead of creating a separate App Registration in each tenant, you can create a **single multi-tenant app** and have each tenant admin consent to it.

### Step 1: Create a Multi-Tenant App

The included `Create-EnterpriseApp.ps1` creates a multi-tenant app by default:

```powershell
.\deploy\Create-EnterpriseApp.ps1 -AppName "MSP-SPO-Automation"
```

This sets `SignInAudience = "AzureADMultipleOrgs"`, allowing the app to be used in any Entra ID tenant.

### Step 2: Generate a Consent URL

Share this URL with each tenant administrator to grant consent:

```
https://login.microsoftonline.com/{tenant-id}/adminconsent?client_id={your-client-id}&redirect_uri=https://localhost
```

Replace `{tenant-id}` with the target tenant's ID or domain (e.g., `contoso.onmicrosoft.com`), and `{your-client-id}` with your app's Client ID.

### Step 3: Tenant Admin Grants Consent

The tenant admin clicks the URL, signs in, reviews the permissions, and clicks **Accept**. This creates a Service Principal in their tenant.

### Step 4: Upload Certificate to the App

> **Important**: You can use the **same certificate** across all tenants (simpler) or generate **separate certificates** per tenant (more secure).

**Same certificate approach:**
```powershell
# One certificate for all tenants
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -match "MSP-SPO" }
$base64 = [Convert]::ToBase64String($cert.Export("Pfx", "password"))
# Use this $base64 for all tenant requests
```

**Per-tenant certificate approach:**
```powershell
# Generate a unique cert per tenant
$tenants = @("contoso", "fabrikam", "litware")
foreach ($tenant in $tenants) {
    $cert = New-SelfSignedCertificate -Subject "CN=MSP-SPO-$tenant" `
        -CertStoreLocation "Cert:\CurrentUser\My" -KeyExportPolicy Exportable
    # Upload public key to the app in that tenant, save PFX Base64
}
```

---

## Making Multi-Tenant API Calls

### Basic Pattern

```powershell
function Invoke-SPOScript {
    param(
        [string]$ApiUrl,
        [string]$FunctionKey,
        [hashtable]$TenantConfig,
        [string]$Script
    )
    $body = @{
        tenantId          = $TenantConfig.TenantId
        clientId          = $TenantConfig.ClientId
        certificateBase64 = $TenantConfig.CertBase64
        spoUrl            = $TenantConfig.SpoUrl
        script            = $Script
    } | ConvertTo-Json

    Invoke-RestMethod -Uri "$ApiUrl/api/InvokeScript?code=$FunctionKey" `
        -Method POST -Body $body -ContentType "application/json"
}

# Define tenant configurations
$tenants = @{
    Contoso = @{
        TenantId  = "aaaa-bbbb-cccc-dddd"
        ClientId  = "1111-2222-3333-4444"
        CertBase64 = $contosoCert
        SpoUrl    = "https://contoso.sharepoint.com"
    }
    Fabrikam = @{
        TenantId  = "eeee-ffff-gggg-hhhh"
        ClientId  = "5555-6666-7777-8888"
        CertBase64 = $fabrikamCert
        SpoUrl    = "https://fabrikam.sharepoint.com"
    }
}

# Run the same script against all tenants
$apiUrl = "https://your-app.azurecontainerapps.io"
$functionKey = "your-function-key"

foreach ($name in $tenants.Keys) {
    Write-Host "Processing tenant: $name"
    $result = Invoke-SPOScript -ApiUrl $apiUrl -FunctionKey $functionKey `
        -TenantConfig $tenants[$name] `
        -Script "Get-PnPWeb | Select-Object Title, Url | ConvertTo-Json"
    Write-Host $result
}
```

### Parallel Execution

For faster processing across many tenants:

```powershell
$tenants.Keys | ForEach-Object -Parallel {
    $tenant = $using:tenants[$_]
    $apiUrl = $using:apiUrl
    $key = $using:functionKey

    $body = @{
        tenantId          = $tenant.TenantId
        clientId          = $tenant.ClientId
        certificateBase64 = $tenant.CertBase64
        spoUrl            = $tenant.SpoUrl
        script            = "Get-PnPTenantSite | Measure-Object | Select-Object Count | ConvertTo-Json"
    } | ConvertTo-Json

    $result = Invoke-RestMethod -Uri "$apiUrl/api/InvokeScript?code=$key" `
        -Method POST -Body $body -ContentType "application/json"

    [PSCustomObject]@{ Tenant = $_; SiteCount = $result.Count }
} -ThrottleLimit 5
```

---

## Storing Tenant Credentials Securely

### Option 1: Azure Key Vault (Recommended)

Store each tenant's credentials as Key Vault secrets:

```powershell
# Store tenant config
$tenantConfig = @{
    TenantId  = "aaaa-bbbb-cccc-dddd"
    ClientId  = "1111-2222-3333-4444"
    CertBase64 = "MIIJ+wIBAzCCCbg..."
    SpoUrl    = "https://contoso.sharepoint.com"
} | ConvertTo-Json

az keyvault secret set --vault-name "msp-credentials" `
    --name "tenant-contoso" --value $tenantConfig

# Retrieve at runtime
$config = az keyvault secret show --vault-name "msp-credentials" `
    --name "tenant-contoso" --query value -o tsv | ConvertFrom-Json
```

### Option 2: Encrypted Configuration File

```powershell
# Encrypt tenant configs with DPAPI (Windows-only)
$tenants | ConvertTo-Json | ConvertTo-SecureString -AsPlainText | ConvertFrom-SecureString | Out-File "tenants.enc"

# Decrypt at runtime
$secure = Get-Content "tenants.enc" | ConvertTo-SecureString
$tenants = [PSCredential]::new("x", $secure).GetNetworkCredential().Password | ConvertFrom-Json
```

---

## Integration with Automation Platforms

### Rewst

The `deploy/` folder includes an empty `rewst_sample_workflow_import.json` for a Rewst workflow template. A typical Rewst integration:

1. **Trigger**: Scheduled or on-demand from Rewst dashboard
2. **Action**: HTTP POST to your API's `/api/InvokeScript`
3. **Input**: Tenant credentials from Rewst's organization variables
4. **Output**: Parse JSON response and route to next workflow step

### Halo PSA / ConnectWise

Use the API from your PSA's custom automation:

```
HTTP POST → https://your-app.azurecontainerapps.io/api/InvokeScript
Headers: Content-Type: application/json
Body: {tenantId, clientId, certificateBase64, spoUrl, script}
```

### Power Automate / Logic Apps

Use the **HTTP** connector in Power Automate:
1. Add an HTTP action
2. Method: POST
3. URI: `https://your-app.azurecontainerapps.io/api/InvokeScript?code=FUNCTION_KEY`
4. Body: JSON with tenant credentials and script

---

## Security Considerations for Multi-Tenant

1. **Use per-tenant certificates** — If one tenant's credential is compromised, it doesn't affect others
2. **Rotate certificates regularly** — Set calendar reminders for certificate expiry
3. **Use Azure Function keys** — Prevents unauthorized access to your API
4. **Add IP restrictions** — Limit who can call your API (see [DEPLOYMENT.md](DEPLOYMENT.md))
5. **Audit logging** — Enable Application Insights to track which tenants are being accessed and by whom
6. **Least privilege** — Consider using `Sites.Selected` instead of `Sites.FullControl.All` where possible
7. **Isolate MSP credentials** — Don't store tenant credentials in the same Key Vault as other secrets

---

## Tenant Onboarding Checklist

For each new tenant you onboard:

- [ ] Tenant admin consents to your multi-tenant app (via consent URL)
- [ ] Generate or assign a certificate for the tenant
- [ ] Upload the certificate's public key to the app in that tenant
- [ ] Store the tenant's credentials (Tenant ID, Client ID, PFX Base64) securely
- [ ] Test with a simple script: `Get-PnPWeb | Select Title | ConvertTo-Json`
- [ ] Document the tenant's SPO URL and admin URL
- [ ] Add the tenant to your automation scripts/platform
