using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

Write-Host "PowerShell HTTP trigger function processed an InvokeScript request."

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
function New-ErrorResponse {
    param(
        [HttpStatusCode]$StatusCode,
        [string]$ErrorCode,
        [string]$Message,
        [string]$Details = $null
    )
    $body = @{
        error     = $ErrorCode
        message   = $Message
        timestamp = (Get-Date -Format "o")
    }
    if ($Details) { $body.details = $Details }
    return [HttpResponseContext]@{
        StatusCode  = $StatusCode
        Body        = $body
        ContentType = "application/json"
    }
}

# ============================================================================
# EXTRACT PARAMETERS
# ============================================================================
$tenantId = $env:TENANT_ID
$clientId = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$certThumbprint = $env:CERTIFICATE_THUMBPRINT
$certBase64 = $env:CERTIFICATE_BASE64
$certPassword = $env:CERTIFICATE_PASSWORD
$spoUrl = $env:SPO_URL

$bodyParams = $Request.Body
$script = $null
$timeoutSeconds = 300

# Override with body parameters if provided
if ($bodyParams) {
    if ($bodyParams.tenantId) { $tenantId = $bodyParams.tenantId }
    if ($bodyParams.clientId) { $clientId = $bodyParams.clientId }
    if ($bodyParams.clientSecret) { $clientSecret = $bodyParams.clientSecret }
    if ($bodyParams.certificateThumbprint) { $certThumbprint = $bodyParams.certificateThumbprint }
    if ($bodyParams.certificateBase64) { $certBase64 = $bodyParams.certificateBase64 }
    if ($bodyParams.certificatePassword) { $certPassword = $bodyParams.certificatePassword }
    if ($bodyParams.spoUrl) { $spoUrl = $bodyParams.spoUrl }
    if ($bodyParams.script) { $script = $bodyParams.script }
    if ($bodyParams.timeoutSeconds) { $timeoutSeconds = [int]$bodyParams.timeoutSeconds }
}

# ============================================================================
# VALIDATE PARAMETERS
# ============================================================================
$missingParams = @()
if (-not $tenantId) { $missingParams += "tenantId" }
if (-not $clientId) { $missingParams += "clientId" }
if (-not $spoUrl)   { $missingParams += "spoUrl" }

if ($missingParams.Count -gt 0) {
    Push-OutputBinding -Name Response -Value (New-ErrorResponse `
        -StatusCode ([HttpStatusCode]::BadRequest) `
        -ErrorCode "MISSING_REQUIRED_PARAMS" `
        -Message "Missing required parameters: $($missingParams -join ', '). Provide them in environment variables or request body." `
        -Details "Required: tenantId (GUID), clientId (GUID), spoUrl (e.g., https://contoso.sharepoint.com)")
    return
}

if (-not $clientSecret -and -not $certThumbprint -and -not $certBase64) {
    Push-OutputBinding -Name Response -Value (New-ErrorResponse `
        -StatusCode ([HttpStatusCode]::BadRequest) `
        -ErrorCode "MISSING_AUTH_CREDENTIAL" `
        -Message "No authentication credential provided. Supply one of: certificateBase64, certificateThumbprint, or clientSecret." `
        -Details "Certificate-based auth (certificateBase64) is recommended for production and multi-tenant scenarios.")
    return
}

if (-not $script) {
    Push-OutputBinding -Name Response -Value (New-ErrorResponse `
        -StatusCode ([HttpStatusCode]::BadRequest) `
        -ErrorCode "MISSING_SCRIPT" `
        -Message "Missing 'script' property in the JSON request body." `
        -Details "Provide a 'script' property containing the PnP PowerShell code to execute. Example: {\"script\": \"Get-PnPWeb | Select Title | ConvertTo-Json\"}")
    return
}

# Validate spoUrl format
if ($spoUrl -notmatch '^https://[a-zA-Z0-9\-]+\.sharepoint\.com') {
    Push-OutputBinding -Name Response -Value (New-ErrorResponse `
        -StatusCode ([HttpStatusCode]::BadRequest) `
        -ErrorCode "INVALID_SPO_URL" `
        -Message "spoUrl must be a valid SharePoint Online URL." `
        -Details "Expected format: https://contoso.sharepoint.com or https://contoso.sharepoint.com/sites/MySite. Received: $spoUrl")
    return
}

# Clamp timeout to reasonable bounds
if ($timeoutSeconds -lt 10) { $timeoutSeconds = 10 }
if ($timeoutSeconds -gt 900) { $timeoutSeconds = 900 }

$tempCertPath = $null
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$warnings = @()

try {
    Write-Host "Connecting to PnP Online..."
    
    # Connect using CBA (Certificate) or Secret
    if ($certBase64) {
        try {
            $bytes = [Convert]::FromBase64String($certBase64)
        } catch {
            Push-OutputBinding -Name Response -Value (New-ErrorResponse `
                -StatusCode ([HttpStatusCode]::BadRequest) `
                -ErrorCode "INVALID_CERTIFICATE_BASE64" `
                -Message "The certificateBase64 value is not valid Base64." `
                -Details "Ensure the string is a valid Base64-encoded PFX. Generate with: [Convert]::ToBase64String([IO.File]::ReadAllBytes('cert.pfx'))")
            return
        }
        $tempCertPath = Join-Path $env:TEMP "$([guid]::NewGuid()).pfx"
        [IO.File]::WriteAllBytes($tempCertPath, $bytes)

        $connectParams = @{
            Url              = $spoUrl
            ClientId         = $clientId
            Tenant           = $tenantId
            CertificatePath  = $tempCertPath
            ReturnConnection = $true
            ErrorAction      = 'Stop'
        }
        if ($certPassword) {
            $connectParams.CertificatePassword = (ConvertTo-SecureString -String $certPassword -AsPlainText -Force)
        }
        $conn = Connect-PnPOnline @connectParams
    }
    elseif ($certThumbprint) {
        $conn = Connect-PnPOnline -Url $spoUrl -ClientId $clientId -Tenant $tenantId -Thumbprint $certThumbprint -ReturnConnection -ErrorAction Stop
    } else {
        $conn = Connect-PnPOnline -Url $spoUrl -ClientId $clientId -ClientSecret $clientSecret -ReturnConnection -ErrorAction Stop
    }

    Write-Host "Executing custom script block (timeout: ${timeoutSeconds}s)..."
    
    # Create the scriptblock from the provided string
    $scriptBlock = [ScriptBlock]::Create($script)
    
    # Execute the scriptblock with timeout.
    # We pass $conn in case the script explicitly asks for it as args[0].
    # By default, PnP commands will use the ambient connection context established above.
    $job = Start-Job -ScriptBlock {
        param($sb, $connection)
        # Re-import PnP module in the job scope
        Import-Module PnP.PowerShell -ErrorAction SilentlyContinue
        $result = Invoke-Command -ScriptBlock ([ScriptBlock]::Create($sb)) -ArgumentList $connection
        return $result
    } -ArgumentList $script, $conn

    $completed = $job | Wait-Job -Timeout $timeoutSeconds

    if ($job.State -eq 'Running') {
        $job | Stop-Job
        $job | Remove-Job -Force
        Push-OutputBinding -Name Response -Value (New-ErrorResponse `
            -StatusCode ([HttpStatusCode]::RequestTimeout) `
            -ErrorCode "SCRIPT_TIMEOUT" `
            -Message "Script execution exceeded the timeout of $timeoutSeconds seconds." `
            -Details "Increase the timeout by adding 'timeoutSeconds' to the request body (max 900), or optimize your script to run faster.")
        return
    }

    $result = $job | Receive-Job
    $jobError = $job.ChildJobs[0].Error

    if ($jobError -and $jobError.Count -gt 0) {
        $warnings += $jobError | ForEach-Object { $_.ToString() }
    }

    $job | Remove-Job -Force

    # If job execution failed but we got results inline instead, try direct execution
    if ($null -eq $result -and $null -eq $completed) {
        $result = Invoke-Command -ScriptBlock $scriptBlock -ArgumentList $conn
    }

    $stopwatch.Stop()

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = @{
            success         = $true
            data            = $result
            executionTimeMs = $stopwatch.ElapsedMilliseconds
            warnings        = $warnings
        }
        ContentType = "application/json"
    })
} catch {
    $stopwatch.Stop()
    Write-Error "Script execution failed: $_"

    $errorCode = "SCRIPT_EXECUTION_FAILED"
    $errorMessage = $_.Exception.Message

    # Provide more specific error codes for common failures
    if ($errorMessage -match "Connect-PnPOnline") {
        $errorCode = "CONNECTION_FAILED"
        $errorMessage = "Failed to establish PnP connection to SharePoint. Verify your credentials and spoUrl."
    } elseif ($errorMessage -match "is not recognized") {
        $errorCode = "UNKNOWN_CMDLET"
    } elseif ($errorMessage -match "Access denied|Unauthorized|403") {
        $errorCode = "ACCESS_DENIED"
    }

    Push-OutputBinding -Name Response -Value (New-ErrorResponse `
        -StatusCode ([HttpStatusCode]::InternalServerError) `
        -ErrorCode $errorCode `
        -Message $errorMessage `
        -Details $_.ScriptStackTrace)
} finally {
    # Clean up the temporary certificate file if it was created
    if ($tempCertPath -and (Test-Path $tempCertPath)) {
        Remove-Item $tempCertPath -Force -ErrorAction SilentlyContinue
    }
}
