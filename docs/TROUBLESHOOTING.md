# Troubleshooting Guide

Common issues and their solutions when using the SPO PowerShell API.

---

## Quick Diagnostic Steps

Before diving into specific errors, run through this checklist:

1. **Is the service running?** → `GET /api/HealthCheck`
2. **Is PnP module loaded?** → Check `pnpModuleVersion` in HealthCheck response
3. **Are credentials correct?** → Try `POST /api/GenerateToken` first (isolates auth from script errors)
4. **Is the SPO URL correct?** → Must be `https://tenant.sharepoint.com` (not the admin URL, unless running admin cmdlets)

---

## Authentication Errors

### `Failed to load certificate from Base64`

**Cause**: The Base64 string is either corrupt, not a PFX, or has a password that wasn't provided.

**Solutions**:
1. Ensure you're providing a **PFX** (not a .cer or .pem) as Base64:
   ```powershell
   # Correct: export as PFX with private key
   $base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.pfx"))
   ```
2. If the PFX has a password, include `certificatePassword` in the request body:
   ```json
   {
     "certificateBase64": "MIIJ+wIBAzCCCbg...",
     "certificatePassword": "YourPfxPassword"
   }
   ```
3. Verify the Base64 string hasn't been truncated (PFX Base64 strings are typically 5000-15000 characters)

### `Certificate does not have a private key`

**Cause**: You exported the public certificate (.cer) instead of the full PFX with the private key.

**Solution**: Re-export as PFX:
```powershell
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -match "SPO" }
$password = ConvertTo-SecureString "YourPassword" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath "cert.pfx" -Password $password
$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.pfx"))
```

### `Certificate not found` (thumbprint mode)

**Cause**: The certificate isn't installed in either `Cert:\CurrentUser\My` or `Cert:\LocalMachine\My` on the container.

**Solution**: For containerized deployments, use Base64 PFX instead of thumbprint. Thumbprint mode only works when the certificate is pre-installed in the container's certificate store.

### `All signing methods failed`

**Cause**: The certificate's private key uses an unsupported algorithm or key container format.

**Solutions**:
1. Ensure the certificate uses **RSA 2048+** with **SHA256** (not ECDSA or DSA)
2. Re-generate the certificate with explicit key parameters:
   ```powershell
   New-SelfSignedCertificate -Subject "CN=SPO-API" `
       -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
       -CertStoreLocation "Cert:\CurrentUser\My" `
       -KeyExportPolicy Exportable -KeySpec Signature
   ```
3. If using an existing cert from a CA, ensure the private key is **exportable**

### `AADSTS700016: Application not found`

**Cause**: The `clientId` doesn't match any App Registration in the specified tenant.

**Solutions**:
1. Double-check the `clientId` GUID
2. Ensure the App Registration exists in the tenant specified by `tenantId`
3. For multi-tenant apps, ensure the app has been consented in the target tenant

### `AADSTS7000215: Invalid client secret`

**Cause**: The client secret is expired or incorrect.

**Solutions**:
1. Check the expiry date of the client secret in Entra ID
2. Generate a new client secret if expired
3. Consider switching to certificate-based auth (secrets expire, certificates are more reliable)

---

## Permission Errors

### `Access denied` / `403 Forbidden` on SPO Operations

**Cause**: The App Registration doesn't have the required SharePoint permissions, or admin consent hasn't been granted.

**Solutions**:
1. In Azure Portal → Entra ID → App Registrations → [Your App] → API Permissions:
   - Verify `SharePoint > Sites.FullControl.All` (Application) is listed
   - Click **"Grant admin consent"** if the status shows "Not granted"
2. If using `Sites.Selected`, ensure the specific site has been granted access:
   ```powershell
   # Check current permissions
   Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/sites/{site-id}/permissions"
   ```

### `The remote server returned an error: (401) Unauthorized`

**Cause**: The access token is invalid, expired, or scoped to the wrong audience.

**Solutions**:
1. Call `/api/GenerateToken` and check the `scope` in the response — it should match your SPO URL
2. Ensure `spoUrl` uses the correct format: `https://contoso.sharepoint.com` (not `https://contoso.sharepoint.com/sites/something`)
3. For admin operations, use the admin URL: `https://contoso-admin.sharepoint.com`

---

## Script Execution Errors

### `The term 'Get-PnPXxx' is not recognized`

**Cause**: The PnP module version may not include the cmdlet you're trying to use.

**Solutions**:
1. Check the module version via `/api/HealthCheck`
2. Verify the cmdlet name — PnP cmdlets are case-sensitive and namespace-specific
3. Some cmdlets require the admin URL (e.g., `Get-PnPTenantSite` needs `contoso-admin.sharepoint.com`)

### Script returns no output / empty response

**Cause**: The script ran successfully but didn't produce any output, or the output wasn't serialized to JSON.

**Solutions**:
1. Always pipe your results to `ConvertTo-Json` at the end of the script:
   ```json
   {
     "script": "Get-PnPWeb | Select-Object Title, Url | ConvertTo-Json"
   }
   ```
2. Use `Write-Output` (not `Write-Host`) for data that should be returned
3. For complex objects, add `-Depth 3` to `ConvertTo-Json` to avoid truncation

### Script timeout

**Cause**: The script takes longer than the default timeout.

**Solutions**:
1. Add `timeoutSeconds` to the request body (default is 300 seconds):
   ```json
   {
     "script": "Get-PnPTenantSite -Detailed | ConvertTo-Json",
     "timeoutSeconds": 600
   }
   ```
2. Break large operations into smaller batches
3. Use server-side filtering: `Get-PnPTenantSite -Filter "Url -like '*HR*'"`

---

## Docker / Container Issues

### Docker build fails at `Save-Module`

**Cause**: Network issues preventing the PSGallery download, or PSGallery is temporarily unavailable.

**Solutions**:
1. Retry the build (PSGallery has occasional outages)
2. If behind a corporate proxy, configure Docker proxy settings:
   ```bash
   docker build --build-arg HTTP_PROXY=http://proxy:8080 -t pwsh-sp-cba .
   ```

### Container starts but functions don't respond

**Cause**: The Azure Functions runtime hasn't finished starting, or the `AzureWebJobsScriptRoot` isn't set correctly.

**Solutions**:
1. Wait 10-15 seconds after container startup for the runtime to initialize
2. Verify environment variables:
   ```bash
   docker run -p 8080:80 \
     -e AzureWebJobsScriptRoot=/home/site/wwwroot \
     -e AzureFunctionsJobHost__Logging__Console__IsEnabled=true \
     pwsh-sp-cba
   ```
3. Check container logs: `docker logs <container-id>`

### First request is slow (~10-20 seconds)

**Cause**: This is normal — the PowerShell worker needs to initialize on the first request. Subsequent requests are fast (< 2 seconds).

**Note**: This is **not** module installation (which would take 30-60s). The modules are pre-baked in the Docker image. The 10-20s delay is the PowerShell 7.4 runtime startup.

**Solutions**:
1. For production, set `minReplicas: 1` in the Bicep template to keep a warm instance
2. Send a "warmup" request to `/api/HealthCheck` after deployment

---

## Azure Deployment Issues

### Bicep deployment fails with `KeyVault name already exists`

**Cause**: Key Vault names are globally unique. The generated name conflicts with a deleted (soft-deleted) Key Vault.

**Solutions**:
1. Change the `appName` parameter to generate a different Key Vault name
2. Purge the soft-deleted Key Vault:
   ```bash
   az keyvault purge --name old-keyvault-name
   ```

### Container App can't pull secrets from Key Vault

**Cause**: The Managed Identity RBAC assignment hasn't propagated yet (can take 1-5 minutes).

**Solutions**:
1. Wait a few minutes and retry
2. Verify the role assignment:
   ```bash
   az role assignment list --scope /subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/your-kv
   ```

---

## Getting More Help

If your issue isn't listed here:

1. **Check the container logs** for detailed error messages
2. **Open an issue** on [GitHub](https://github.com/Calvindd2f/func-pwsh-sp-cba/issues) with:
   - The error message (full text)
   - Your request body (redact secrets!)
   - The HealthCheck response
   - Docker/Azure environment details
