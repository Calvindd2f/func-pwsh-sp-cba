<#
.SYNOPSIS
    PowerShell client wrapper for the SPO PowerShell API.

.DESCRIPTION
    Provides friendly PowerShell functions for interacting with the SPO PowerShell API:
    - Test-SPOApi          : Check if the API is healthy
    - Get-SPOApiToken      : Generate an OAuth access token
    - Invoke-SPOApiScript  : Execute a PnP PowerShell script against a tenant

.EXAMPLE
    # Import the client
    . .\examples\powershell-client.ps1

    # Configure your API connection
    $api = @{
        BaseUrl     = "http://localhost:8080"
        FunctionKey = ""  # Leave empty for local dev
    }

    # Configure tenant credentials
    $tenant = @{
        TenantId  = "your-tenant-id"
        ClientId  = "your-client-id"
        CertBase64 = "your-base64-pfx"
        SpoUrl    = "https://contoso.sharepoint.com"
    }

    # Check health
    Test-SPOApi -BaseUrl $api.BaseUrl

    # Run a script
    Invoke-SPOApiScript @api @tenant -Script "Get-PnPWeb | Select Title, Url"
#>

function Test-SPOApi {
    <#
    .SYNOPSIS
        Tests if the SPO PowerShell API is healthy and responsive.
    .PARAMETER BaseUrl
        The base URL of the API (e.g., http://localhost:8080 or https://your-app.azurecontainerapps.io)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl
    )

    $url = "$BaseUrl/api/HealthCheck"
    try {
        $response = Invoke-RestMethod -Uri $url -Method GET -ErrorAction Stop
        Write-Host "✅ API is $($response.status)" -ForegroundColor Green
        Write-Host "   PnP Module: $($response.pnpModuleVersion)"
        Write-Host "   PowerShell: $($response.powershellVersion)"
        Write-Host "   Endpoints:  $($response.endpoints -join ', ')"
        return $response
    }
    catch {
        Write-Host "❌ API is unreachable at $url" -ForegroundColor Red
        Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Get-SPOApiToken {
    <#
    .SYNOPSIS
        Generates an OAuth 2.0 access token for SharePoint Online via the API.
    .PARAMETER BaseUrl
        The base URL of the API.
    .PARAMETER FunctionKey
        The Azure Function key (leave empty for local development).
    .PARAMETER TenantId
        The Entra ID tenant ID.
    .PARAMETER ClientId
        The App Registration client ID.
    .PARAMETER CertBase64
        The Base64-encoded PFX certificate.
    .PARAMETER CertPassword
        Optional password for the PFX certificate.
    .PARAMETER ClientSecret
        Client secret (alternative to certificate auth).
    .PARAMETER SpoUrl
        The SharePoint Online root URL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [string]$FunctionKey = "",

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [string]$CertBase64,
        [string]$CertPassword,
        [string]$ClientSecret,

        [Parameter(Mandatory)]
        [string]$SpoUrl
    )

    $url = "$BaseUrl/api/GenerateToken"
    if ($FunctionKey) { $url += "?code=$FunctionKey" }

    $body = @{
        tenantId = $TenantId
        clientId = $ClientId
        spoUrl   = $SpoUrl
    }

    if ($CertBase64)    { $body.certificateBase64    = $CertBase64 }
    if ($CertPassword)  { $body.certificatePassword  = $CertPassword }
    if ($ClientSecret)  { $body.clientSecret          = $ClientSecret }

    try {
        $response = Invoke-RestMethod -Uri $url -Method POST `
            -Body ($body | ConvertTo-Json -Depth 5) `
            -ContentType "application/json" -ErrorAction Stop

        if ($response.success) {
            Write-Host "✅ Token generated successfully" -ForegroundColor Green
            Write-Host "   Scope:      $($response.scope)"
            Write-Host "   Expires in: $($response.expires_in) seconds"
        }
        return $response
    }
    catch {
        $errorBody = $null
        try {
            $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
            $errorBody = $reader.ReadToEnd() | ConvertFrom-Json
        } catch {}

        Write-Host "❌ Token generation failed" -ForegroundColor Red
        if ($errorBody) {
            Write-Host "   Error: $($errorBody.error)" -ForegroundColor Yellow
            Write-Host "   Details: $($errorBody.message)" -ForegroundColor Yellow
        } else {
            Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        return $null
    }
}

function Invoke-SPOApiScript {
    <#
    .SYNOPSIS
        Executes a PnP PowerShell script against a SharePoint tenant via the API.
    .PARAMETER BaseUrl
        The base URL of the API.
    .PARAMETER FunctionKey
        The Azure Function key (leave empty for local development).
    .PARAMETER TenantId
        The Entra ID tenant ID.
    .PARAMETER ClientId
        The App Registration client ID.
    .PARAMETER CertBase64
        The Base64-encoded PFX certificate.
    .PARAMETER CertPassword
        Optional password for the PFX certificate.
    .PARAMETER ClientSecret
        Client secret (alternative to certificate auth).
    .PARAMETER SpoUrl
        The SharePoint Online URL to connect to.
    .PARAMETER Script
        The PnP PowerShell script to execute.
    .PARAMETER TimeoutSeconds
        Script execution timeout in seconds (default: 300).
    .EXAMPLE
        Invoke-SPOApiScript -BaseUrl "http://localhost:8080" `
            -TenantId "xxx" -ClientId "yyy" -CertBase64 "zzz" `
            -SpoUrl "https://contoso.sharepoint.com" `
            -Script "Get-PnPWeb | Select Title"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [string]$FunctionKey = "",

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [string]$CertBase64,
        [string]$CertPassword,
        [string]$ClientSecret,

        [Parameter(Mandatory)]
        [string]$SpoUrl,

        [Parameter(Mandatory)]
        [string]$Script,

        [int]$TimeoutSeconds = 300
    )

    $url = "$BaseUrl/api/InvokeScript"
    if ($FunctionKey) { $url += "?code=$FunctionKey" }

    $body = @{
        tenantId       = $TenantId
        clientId       = $ClientId
        spoUrl         = $SpoUrl
        script         = $Script
        timeoutSeconds = $TimeoutSeconds
    }

    if ($CertBase64)   { $body.certificateBase64   = $CertBase64 }
    if ($CertPassword) { $body.certificatePassword = $CertPassword }
    if ($ClientSecret) { $body.clientSecret         = $ClientSecret }

    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $response = Invoke-RestMethod -Uri $url -Method POST `
            -Body ($body | ConvertTo-Json -Depth 5) `
            -ContentType "application/json" `
            -TimeoutSec $TimeoutSeconds `
            -ErrorAction Stop

        $stopwatch.Stop()
        Write-Host "✅ Script executed in $($stopwatch.ElapsedMilliseconds)ms" -ForegroundColor Green

        return $response
    }
    catch {
        $errorBody = $null
        try {
            $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
            $errorBody = $reader.ReadToEnd() | ConvertFrom-Json
        } catch {}

        Write-Host "❌ Script execution failed" -ForegroundColor Red
        if ($errorBody) {
            Write-Host "   Error: $($errorBody.error)" -ForegroundColor Yellow
            Write-Host "   Details: $($errorBody.message ?? $errorBody.details)" -ForegroundColor Yellow
        } else {
            Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        return $null
    }
}

# =============================================================================
# Convenience Functions for Common Operations
# =============================================================================

function Get-SPOApiSiteInventory {
    <#
    .SYNOPSIS
        Retrieves a full site collection inventory from a tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BaseUrl,
        [string]$FunctionKey = "",
        [Parameter(Mandatory)] [string]$TenantId,
        [Parameter(Mandatory)] [string]$ClientId,
        [string]$CertBase64,
        [string]$ClientSecret,
        [Parameter(Mandatory)] [string]$SpoUrl
    )

    $script = @"
Get-PnPTenantSite -Detailed |
    Select-Object Url, Title, Template, Owner,
        StorageUsageCurrent, StorageMaximumLevel,
        LastContentModifiedDate, LockState,
        SharingCapability, GroupId |
    ConvertTo-Json -Depth 3
"@

    $params = @{} + $PSBoundParameters
    $params.Script = $script
    Invoke-SPOApiScript @params
}

function Get-SPOApiPermissionReport {
    <#
    .SYNOPSIS
        Gets a permission report for a specific site.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BaseUrl,
        [string]$FunctionKey = "",
        [Parameter(Mandatory)] [string]$TenantId,
        [Parameter(Mandatory)] [string]$ClientId,
        [string]$CertBase64,
        [string]$ClientSecret,
        [Parameter(Mandatory)] [string]$SpoUrl
    )

    $script = @"
`$web = Get-PnPWeb -Includes RoleAssignments
`$results = @()
foreach (`$ra in `$web.RoleAssignments) {
    `$member = Get-PnPProperty -ClientObject `$ra -Property Member
    `$roles = Get-PnPProperty -ClientObject `$ra -Property RoleDefinitionBindings
    `$results += [PSCustomObject]@{
        Principal = `$member.Title
        LoginName = `$member.LoginName
        Roles = (`$roles | Select-Object -ExpandProperty Name) -join ", "
    }
}
`$results | ConvertTo-Json
"@

    $params = @{} + $PSBoundParameters
    $params.Script = $script
    Invoke-SPOApiScript @params
}

Write-Host "SPO PowerShell API Client loaded. Available commands:" -ForegroundColor Cyan
Write-Host "  Test-SPOApi               — Check API health"
Write-Host "  Get-SPOApiToken           — Generate an access token"
Write-Host "  Invoke-SPOApiScript       — Execute a PnP script"
Write-Host "  Get-SPOApiSiteInventory   — Get all site collections"
Write-Host "  Get-SPOApiPermissionReport — Get site permissions"
Write-Host ""
Write-Host "Run 'Get-Help <command> -Full' for detailed usage." -ForegroundColor Gray
