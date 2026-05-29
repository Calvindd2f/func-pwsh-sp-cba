<#
.SYNOPSIS
Creates a multi-tenant Enterprise Application (App Registration + Service Principal) in Entra ID and configures a self-signed certificate for authentication.

.DESCRIPTION
This script uses the Microsoft.Graph PowerShell SDK to:
1. Create a multi-tenant Application Registration
2. Create a self-signed certificate locally
3. Upload the public key of the certificate to the App Registration
4. Export the certificate as a Base64 string so it can be passed into the Bicep template for Key Vault

.PREREQUISITES
Install-Module Microsoft.Graph.Applications
#>

param (
    [Parameter(Mandatory=$false)]
    [string]$AppName = "PwshContainerAppAuth",
    [Parameter(Mandatory=$false)]
    [string]$ExportPath = "$env:TEMP\PwshContainerAppCert.pfx",
    [Parameter(Mandatory=$false)]
    [string]$CertPassword = "ChangeMe123!" # Change this for production!
)

Write-Host "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Application.ReadWrite.All", "Directory.ReadWrite.All"

Write-Host "Creating multi-tenant Application Registration: $AppName..."
$appParams = @{
    DisplayName = $AppName
    SignInAudience = "AzureADMultipleOrgs" # Multi-tenant
}
$app = New-MgApplication @appParams
Write-Host "App Registration created. Client ID: $($app.AppId)"

Write-Host "Creating Service Principal in the tenant..."
$spParams = @{
    AppId = $app.AppId
}
$sp = New-MgServicePrincipal @spParams
Write-Host "Service Principal created. Object ID: $($sp.Id)"

Write-Host "Generating self-signed certificate..."
$cert = New-SelfSignedCertificate -Subject "CN=$AppName" -CertStoreLocation "Cert:\CurrentUser\My" -KeyExportPolicy Exportable -KeySpec Signature

Write-Host "Exporting certificate to $ExportPath..."
$securePassword = ConvertTo-SecureString -String $CertPassword -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $ExportPath -Password $securePassword | Out-Null

Write-Host "Extracting public key to upload to Entra ID..."
$certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$base64Cert = [Convert]::ToBase64String($certBytes)

Write-Host "Adding certificate credentials to the App Registration..."
$keyCredential = @{
    Type = "AsymmetricX509Cert"
    Usage = "Verify"
    Key = $certBytes
}
Add-MgApplicationKey -ApplicationId $app.Id -KeyCredential $keyCredential | Out-Null

Write-Host "Exporting the full PFX as Base64 for Azure Key Vault..."
$pfxBytes = [IO.File]::ReadAllBytes($ExportPath)
$base64Pfx = [Convert]::ToBase64String($pfxBytes)

Write-Host "==========================================="
Write-Host "SUCCESS!"
Write-Host "==========================================="
Write-Host "Client ID: $($app.AppId)"
Write-Host "Tenant ID: (Your current Entra ID tenant)"
Write-Host ""
Write-Host "IMPORTANT: Store this Base64 PFX string securely. You will pass this to the 'certificateBase64' parameter in the Bicep template."
Write-Host ""
Write-Host $base64Pfx
Write-Host "==========================================="
