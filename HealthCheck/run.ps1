using namespace System.Net

# HealthCheck endpoint — returns service status, module versions, and available endpoints.
# This endpoint uses anonymous auth so it can serve as a container liveness/readiness probe.
param($Request, $TriggerMetadata)

Write-Host "HealthCheck endpoint called."

try {
    # Check if PnP.PowerShell is available and get its version
    $pnpModule = Get-Module -Name PnP.PowerShell -ListAvailable | Select-Object -First 1
    $pnpVersion = if ($pnpModule) { $pnpModule.Version.ToString() } else { "NOT INSTALLED" }
    $pnpStatus = if ($pnpModule) { "loaded" } else { "missing" }

    # Get PowerShell version
    $psVersion = $PSVersionTable.PSVersion.ToString()

    # Overall health status
    $isHealthy = ($null -ne $pnpModule)
    $status = if ($isHealthy) { "healthy" } else { "degraded" }

    $healthResponse = @{
        status             = $status
        pnpModuleVersion   = $pnpVersion
        pnpModuleStatus    = $pnpStatus
        powershellVersion  = $psVersion
        endpoints          = @(
            "/api/GenerateToken",
            "/api/InvokeScript",
            "/api/HealthCheck"
        )
        environment        = @{
            tenantIdConfigured    = (-not [string]::IsNullOrEmpty($env:TENANT_ID))
            clientIdConfigured    = (-not [string]::IsNullOrEmpty($env:CLIENT_ID))
            spoUrlConfigured      = (-not [string]::IsNullOrEmpty($env:SPO_URL))
            certBase64Configured  = (-not [string]::IsNullOrEmpty($env:CERTIFICATE_BASE64))
            certThumbConfigured   = (-not [string]::IsNullOrEmpty($env:CERTIFICATE_THUMBPRINT))
            clientSecretConfigured = (-not [string]::IsNullOrEmpty($env:CLIENT_SECRET))
        }
        timestamp          = (Get-Date -Format "o")
    }

    $statusCode = if ($isHealthy) { [HttpStatusCode]::OK } else { [HttpStatusCode]::ServiceUnavailable }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = $statusCode
        Body        = $healthResponse
        ContentType = "application/json"
    })
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::InternalServerError
        Body        = @{
            status  = "error"
            error   = $_.Exception.Message
            timestamp = (Get-Date -Format "o")
        }
        ContentType = "application/json"
    })
}
