using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

Write-Host "PowerShell HTTP trigger function processed an InvokeScript request."

# Extract parameters from environment or request body
$tenantId = $env:TENANT_ID
$clientId = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$certThumbprint = $env:CERTIFICATE_THUMBPRINT
$certBase64 = $env:CERTIFICATE_BASE64
$spoUrl = $env:SPO_URL

$bodyParams = $Request.Body
$script = $null

# Override with body parameters if provided
if ($bodyParams) {
    if ($bodyParams.tenantId) { $tenantId = $bodyParams.tenantId }
    if ($bodyParams.clientId) { $clientId = $bodyParams.clientId }
    if ($bodyParams.clientSecret) { $clientSecret = $bodyParams.clientSecret }
    if ($bodyParams.certificateThumbprint) { $certThumbprint = $bodyParams.certificateThumbprint }
    if ($bodyParams.certificateBase64) { $certBase64 = $bodyParams.certificateBase64 }
    if ($bodyParams.spoUrl) { $spoUrl = $bodyParams.spoUrl }
    if ($bodyParams.script) { $script = $bodyParams.script }
}

if (-not $tenantId -or -not $clientId -or -not $spoUrl) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = "Missing tenantId, clientId, or spoUrl. Provide them in environment variables or request body."
    })
    return
}

if (-not $clientSecret -and -not $certThumbprint -and -not $certBase64) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = "Provide clientSecret, certificateThumbprint, or certificateBase64 for authentication."
    })
    return
}

if (-not $script) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = "Missing 'script' property in the JSON request body containing the PowerShell code to execute."
    })
    return
}

$tempCertPath = $null

try {
    Write-Host "Connecting to PnP Online..."
    
    # Connect using CBA (Certificate) or Secret
    if ($certBase64) {
        $bytes = [Convert]::FromBase64String($certBase64)
        $tempCertPath = Join-Path $env:TEMP "$([guid]::NewGuid()).pfx"
        [IO.File]::WriteAllBytes($tempCertPath, $bytes)
        
        $conn = Connect-PnPOnline -Url $spoUrl -ClientId $clientId -Tenant $tenantId -CertificatePath $tempCertPath -ReturnConnection -ErrorAction Stop
    }
    elseif ($certThumbprint) {
        $conn = Connect-PnPOnline -Url $spoUrl -ClientId $clientId -Tenant $tenantId -Thumbprint $certThumbprint -ReturnConnection -ErrorAction Stop
    } else {
        $conn = Connect-PnPOnline -Url $spoUrl -ClientId $clientId -ClientSecret $clientSecret -ReturnConnection -ErrorAction Stop
    }

    Write-Host "Executing custom script block..."
    
    # Create the scriptblock from the provided string
    $scriptBlock = [ScriptBlock]::Create($script)
    
    # Execute the scriptblock. We pass $conn in case the script explicitly asks for it as args[0].
    # By default, PnP commands will use the ambient connection context established above.
    $result = Invoke-Command -ScriptBlock $scriptBlock -ArgumentList $conn
    
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $result
        ContentType = "application/json"
    })
} catch {
    Write-Error "Script execution failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = @{
            error = "Script execution failed"
            details = $_.Exception.Message
        }
        ContentType = "application/json"
    })
} finally {
    # Clean up the temporary certificate file if it was created
    if ($tempCertPath -and (Test-Path $tempCertPath)) {
        Remove-Item $tempCertPath -Force -ErrorAction SilentlyContinue
    }
}
