# Authentication Guide

This guide covers all supported authentication methods, security considerations, and how to set up certificate-based authentication from scratch.

---

## Authentication Methods at a Glance

| Method | Security | Multi-Tenant Ready | Credential Location | Best For |
|---|---|---|---|---|
| **Certificate (Base64 PFX)** | 🟢 High | ✅ Yes | Request body | MSPs, multi-tenant automation |
| **Certificate (Thumbprint)** | 🟢 High | ❌ No | Local cert store | Single-tenant, on-prem |
| **Client Secret** | 🟡 Medium | ✅ Yes | Request body | Quick testing, dev environments |

---

## Recommended: Certificate-Based Authentication (CBA)

Certificate-based auth is the most secure option and the only method that supports multi-tenant scenarios with per-request credentials.

### How It Works

```
1. You create a self-signed certificate (PFX)
2. Upload the PUBLIC key to the Entra ID App Registration
3. Send the PRIVATE key (Base64 PFX) in each API request
4. The function constructs a JWT assertion signed with your private key
5. Microsoft validates the JWT against the uploaded public key
6. An access token is issued
```

### Step-by-Step: Generate a Certificate

#### Option 1: Using the Included Script (Recommended)

```powershell
# This creates the app, generates the cert, uploads the public key, and exports the PFX
.\deploy\Create-EnterpriseApp.ps1 -AppName "SPO-API-Auth"
```

#### Option 2: Manual Certificate Generation

```powershell
# 1. Create a self-signed certificate
$cert = New-SelfSignedCertificate `
    -Subject "CN=SPO-API-Auth" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy Exportable `
    -KeySpec Signature `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(2)

# 2. Export as PFX (contains private key)
$password = ConvertTo-SecureString -String "YourPassword" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath ".\spo-auth.pfx" -Password $password

# 3. Convert PFX to Base64 for API usage
$base64Pfx = [Convert]::ToBase64String([IO.File]::ReadAllBytes(".\spo-auth.pfx"))
$base64Pfx | Set-Clipboard  # Copy to clipboard
Write-Host "Base64 PFX copied to clipboard (length: $($base64Pfx.Length) chars)"

# 4. Export public key (.cer) for Entra ID upload
Export-Certificate -Cert $cert -FilePath ".\spo-auth.cer"

# 5. Upload the .cer file to your App Registration in Azure Portal:
#    Entra ID → App Registrations → [Your App] → Certificates & Secrets → Upload Certificate
```

### Using Certificate Auth in API Calls

```json
{
  "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "clientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "certificateBase64": "MIIJ+wIBAzCCCbg...",
  "certificatePassword": "YourPassword",
  "spoUrl": "https://contoso.sharepoint.com"
}
```

> **Note**: If your PFX has no password (exported without one), omit the `certificatePassword` field entirely.

### JWT Signing — Under the Hood

The `GenerateToken` function constructs a JWT client assertion with this structure:

**Header:**
```json
{
  "alg": "RS256",
  "typ": "JWT",
  "x5t": "<base64url-encoded certificate thumbprint>"
}
```

**Payload:**
```json
{
  "aud": "https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token",
  "iss": "{clientId}",
  "sub": "{clientId}",
  "jti": "<unique GUID>",
  "nbf": 1700000000,
  "exp": 1700000300,
  "iat": 1700000000
}
```

The function uses a **4-method fallback chain** for signing, ensuring compatibility with various certificate key types:

1. **CNG (GetRSAPrivateKey)** — Modern .NET, preferred
2. **CNG (Export + Reimport)** — Fallback for non-CNG certs
3. **Enhanced CSP (CspParameters)** — CAPI compatibility with SHA256
4. **Manual OID (2.16.840.1.101.3.4.2.1)** — Last resort for legacy providers

---

## Client Secret Authentication

Simpler but less secure. Client secrets:
- ⚠️ Expire (max 2 years) and must be rotated manually
- ⚠️ Are plain strings that can be leaked in logs, source code, or config files
- ⚠️ Cannot be scoped to specific permissions beyond the app's configured access

### Using Client Secret in API Calls

```json
{
  "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "clientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "clientSecret": "your-client-secret-value",
  "spoUrl": "https://contoso.sharepoint.com"
}
```

---

## Certificate by Thumbprint

This method uses a certificate already installed in the machine's certificate store. It's only usable in single-tenant scenarios where the certificate is pre-installed on the container or server.

### Setup

1. Install the certificate in `Cert:\CurrentUser\My` or `Cert:\LocalMachine\My`
2. Note the thumbprint (40-character hex string)
3. Set the `CERTIFICATE_THUMBPRINT` environment variable or pass it in the request body

### Using Thumbprint in API Calls

```json
{
  "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "clientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "certificateThumbprint": "A1B2C3D4E5F6...",
  "spoUrl": "https://contoso.sharepoint.com"
}
```

---

## Environment Variables vs. Per-Request Credentials

You can provide credentials in two ways:

### 1. Environment Variables (Default Credentials)

Set these on the container or in `local.settings.json`:

```
TENANT_ID=your-tenant-id
CLIENT_ID=your-client-id
CERTIFICATE_BASE64=your-base64-pfx
SPO_URL=https://contoso.sharepoint.com
```

The API will use these if no credentials are provided in the request body.

### 2. Per-Request Credentials (Multi-Tenant)

Include credentials in the JSON request body. **Request body values always override environment variables.** This is the pattern for multi-tenant usage — deploy one instance, pass different tenant credentials per request.

```json
{
  "tenantId": "different-tenant-id",
  "clientId": "different-client-id",
  "certificateBase64": "different-base64-pfx",
  "spoUrl": "https://different-tenant.sharepoint.com",
  "script": "Get-PnPWeb"
}
```

---

## Required Entra ID Permissions

Your App Registration needs these API permissions:

| API | Permission | Type | Why |
|---|---|---|---|
| SharePoint (`00000003-0000-0ff1-ce00-000000000000`) | `Sites.FullControl.All` | Application | Full access to all site collections via PnP |

### How to Grant Permissions

**Via Azure Portal:**
1. Entra ID → App Registrations → [Your App] → API Permissions
2. Add Permission → SharePoint → Application → `Sites.FullControl.All`
3. Click "Grant admin consent for [Your Org]"

**Via PowerShell (automated):**
```powershell
# The sp-pnp-setup-prereq.ps1 script handles this automatically
.\sp-pnp-setup-prereq.ps1 -TenantDomain "contoso.onmicrosoft.com" -AdminUPN "admin@contoso.com"
```

### Scoping Down Permissions

`Sites.FullControl.All` is broad. If you want to limit access:

- **Sites.Selected** — Grants access only to specific site collections you designate. Requires per-site permission grants via Graph API.
- Use the `Sites.Selected` permission and then grant per-site access:
  ```powershell
  # Grant app access to a specific site
  $siteId = "contoso.sharepoint.com,site-id,web-id"
  $body = @{
      roles = @("write")
      grantedToIdentities = @(@{
          application = @{ id = "your-client-id"; displayName = "SPO-API" }
      })
  }
  Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/sites/$siteId/permissions" -Body $body
  ```

---

## Security Best Practices

1. **Use certificates, not secrets** — Certificates can't be accidentally logged as plain text
2. **Use short-lived certificates** — 1-2 year expiry, rotate before expiry
3. **Store PFX Base64 in Key Vault** — The Bicep template does this automatically
4. **Use HTTPS** — The Container App enforces TLS by default
5. **Use Azure Function keys** — Both endpoints require a function key (`authLevel: function`)
6. **Scope permissions** — Use `Sites.Selected` instead of `Sites.FullControl.All` where possible
7. **Monitor usage** — Enable Application Insights to track who's calling your API
