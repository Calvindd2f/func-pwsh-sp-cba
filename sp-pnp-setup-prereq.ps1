<#
.SYNOPSIS
    Creates a new App Registration for SharePoint automation with cert‑based auth.
.DESCRIPTION
    - Connects to Microsoft Graph as an admin.
    - Generates a self‑signed certificate and uploads it to the app.
    - Assigns the Sites.FullControl.All application permission and grants admin consent.
    - Sets ACL on the certificate's private key for a service account (optional).
    - Exports the public key (.cer) and (if chosen) a PFX file.
    - Outputs the tenant ID, client ID and certificate thumbprint for use with Connect‑PnPOnline etc.
.NOTES
    Author: Community Script
    Requires: Microsoft.Graph.Authentication module (Install‑Module Microsoft.Graph.Authentication)
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TenantDomain,               # e.g. "contoso.onmicrosoft.com"

    [Parameter(Mandatory=$true)]
    [string]$AdminUPN,                   # GA or App Admin to consent

    [Parameter(Mandatory=$false)]
    [string]$AppName = "SPOCertAutomation",

    [Parameter(Mandatory=$false)]
    [string]$ServiceAccount = $null,     # e.g. "NT SERVICE\ADSync"

    [Parameter(Mandatory=$false)]
    [string]$CertExportPath = ".",       # folder for .cer / .pfx

    [Parameter(Mandatory=$false)]
    [string]$CertPassword = $null,       # if you want a PFX (set a password)

    [Parameter(Mandatory=$false)]
    [switch]$AllowCertificateExport       # if absent, private key is non‑exportable
)

#region Helper functions
function Connect-AdminGraph {
    param($AdminUPN, $TenantDomain)
    Write-Host "Connecting to Microsoft Graph as $AdminUPN ..."
    Connect-MgGraph -Scopes @("Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All") -TenantId $TenantDomain
}

function New-SelfSignedCertForAuth {
    param(
        [string]$AppName,
        [string]$CertExportPath,
        [switch]$AllowCertificateExport
    )
    $dns = "$AppName.$TenantDomain"
    $params = @{
        Subject           = "CN=$dns"
        DnsName           = $dns
        CertStoreLocation = "Cert:\CurrentUser\My"   # easier for ACL later
        KeyAlgorithm      = "RSA"
        KeyLength         = 2048
        HashAlgorithm     = "SHA256"
        NotAfter          = (Get-Date).AddYears(2)
        KeyExportPolicy   = if ($AllowCertificateExport) { "Exportable" } else { "NonExportable" }
    }
    $cert = New-SelfSignedCertificate @params
    Write-Host "Created certificate with thumbprint: $($cert.Thumbprint)"
    return $cert
}

function Export-CertificateFiles {
    param($Cert, $Path, $AllowExport, $Password)
    # Export public key (.cer)
    $cerBytes = $Cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $cerFile = Join-Path $Path "$($Cert.Thumbprint).cer"
    [System.IO.File]::WriteAllBytes($cerFile, $cerBytes)

    if ($AllowExport -and $Password) {
        $pfxBytes = $Cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $Password)
        $pfxFile = Join-Path $Path "$($Cert.Thumbprint).pfx"
        [System.IO.File]::WriteAllBytes($pfxFile, $pfxBytes)
        Write-Host "PFX exported to $pfxFile"
    }
}

function Set-CertificatePrivateKeyAcl {
    param($Cert, $ServiceAccount)
    if (-not $ServiceAccount) { return }

    $rsaCert = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if ($null -eq $rsaCert) { throw "Could not get RSA private key" }

    $keyUniqueName = ($rsaCert.Key).UniqueName
    $keyPath = "$env:ALLUSERSPROFILE\Microsoft\Crypto\RSA\MachineKeys\$keyUniqueName"
    if (-not (Test-Path $keyPath)) {
        # For User store it might be under CurrentUser\... but we used CurrentUser\My
        $keyPath = "$env:APPDATA\Microsoft\Crypto\RSA\$($env:USERNAME)_S-1-5-21-...??" 
        # Better: use the CngKey approach
        $cngKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        $keyPath = $cngKey.Key.UniqueName | ForEach-Object { "$env:ALLUSERSPROFILE\Microsoft\Crypto\Keys\$_" }
    }
    if (-not (Test-Path $keyPath)) {
        Write-Warning "Private key file not found at $keyPath, ACL not modified"
        return
    }
    $acl = Get-Acl $keyPath
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule $ServiceAccount, 'Read', 'Allow'
    $acl.AddAccessRule($rule)
    Set-Acl -Path $keyPath -AclObject $acl
    Write-Host "Granted Read access to $ServiceAccount on $keyPath"
}
#endregion

# 1. Connect to Graph (admin user)
Connect-AdminGraph -AdminUPN $AdminUPN -TenantDomain $TenantDomain

# 2. Generate certificate
$cert = New-SelfSignedCertForAuth -AppName $AppName -CertExportPath $CertExportPath -AllowCertificateExport:$AllowCertificateExport

# 3. Build App Registration payload (JSON)
$tenantId = (Get-MgContext).TenantId
$reqBody = @{
    displayName = $AppName
    signInAudience = "AzureADMyOrg"
    requiredResourceAccess = @(
        @{
            resourceAppId = "00000003-0000-0ff1-ce00-000000000000"  # SharePoint Online
            resourceAccess = @(
                @{
                    id   = "678536fe-1083-478a-9c59-b99265e6b0d3"  # Sites.FullControl.All (Application)
                    type = "Role"
                }
            )
        }
    )
    keyCredentials = @(
        @{
            type  = "AsymmetricX509Cert"
            usage = "Verify"
            key   = [System.Convert]::ToBase64String($cert.GetRawCertData())
        }
    )
}

# 4. Create App Registration
$graphUri = "https://graph.microsoft.com/v1.0/applications"
try {
    $app = Invoke-MgGraphRequest -Method POST -Uri $graphUri -Body $reqBody -ContentType "application/json"
    $clientId = $app.appId
    Write-Host "App registration created with AppId: $clientId"
}
catch {
    # If app already exists, retrieve it
    Write-Warning "Creation failed, trying to find existing app named '$AppName'"
    $existing = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$AppName'" -Method GET
    if ($existing.value.Count -eq 1) {
        $app = $existing.value[0]
        $clientId = $app.appId
        # Update key credential
        $patchUri = "https://graph.microsoft.com/v1.0/applications/$($app.id)"
        $patchBody = @{
            keyCredentials = $reqBody.keyCredentials
        }
        Invoke-MgGraphRequest -Method PATCH -Uri $patchUri -Body $patchBody -ContentType "application/json"
        Write-Host "Updated existing app with new certificate."
        # Also ensure required permissions are present (updating existing apps not shown for brevity)
    }
    else {
        throw "Could not create or find app with name $AppName"
    }
}

# 5. Grant admin consent
# First, locate the service principal for SharePoint Online
$spSPO = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0ff1-ce00-000000000000'" -Method GET
if ($spSPO.value.Count -ne 1) { throw "SharePoint Online service principal not found" }
$spoSpId = $spSPO.value[0].id

# Find the app role ID for Sites.FullControl.All
$role = $spSPO.value[0].appRoles | Where-Object { $_.value -eq "Sites.FullControl.All" -and $_.allowedMemberTypes -contains "Application" }
if (-not $role) { throw "Sites.FullControl.All role not found" }

# Grant admin consent (POST to servicePrincipal appRoleAssignments)
$grantUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$clientId/appRoleAssignments"
$grantBody = @{
    principalId = $clientId
    resourceId = $spoSpId
    appRoleId  = $role.id
}
try {
    Invoke-MgGraphRequest -Method POST -Uri $grantUri -Body $grantBody -ContentType "application/json"
    Write-Host "Admin consent granted for Sites.FullControl.All"
}
catch {
    if ($_.Exception.Message -match "Permission already exists") {
        Write-Host "Permission already consented."
    } else { throw }
}

# 6. Prepare certificate for use (export, ACL)
Export-CertificateFiles -Cert $cert -Path $CertExportPath -AllowExport:$AllowCertificateExport -Password $CertPassword
Set-CertificatePrivateKeyAcl -Cert $cert -ServiceAccount $ServiceAccount

# 7. Output connection details
Write-Host "`n--- Configuration for SharePoint Online / PnP PowerShell ---"
Write-Host "Tenant ID:            $tenantId"
Write-Host "Client ID:            $clientId"
Write-Host "Certificate Thumbprint: $($cert.Thumbprint)"
Write-Host "Certificate file:      $(Join-Path $CertExportPath "$($cert.Thumbprint).cer")"
Write-Host "`nYou can now connect with:"
Write-Host "Connect-PnPOnline -Url https://$($TenantDomain.Split('.')[0]).sharepoint.com -Tenant $tenantId -ClientId $clientId -Thumbprint $($cert.Thumbprint)"
Write-Host "Connect-SPOService -Url https://$($TenantDomain.Split('.')[0])-admin.sharepoint.com -Tenant $tenantId -ClientId $clientId -Thumbprint $($cert.Thumbprint)"
Write-Host "(Ensure the certificate is installed in the personal store of the account running the command.)"