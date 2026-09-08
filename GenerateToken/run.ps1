using namespace System.Net
using namespace System.Security.Cryptography.X509Certificates

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

Write-Host "PowerShell HTTP trigger function processed a GenerateToken request."

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
function ConvertTo-Base64UrlString {
    param([byte[]]$Bytes)
    $base64 = [Convert]::ToBase64String($Bytes)
    return $base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-UnixTimestamp {
    $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    return [int]([DateTime]::UtcNow - $epoch).TotalSeconds
}

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
if ($bodyParams) {
    if ($bodyParams.tenantId) { $tenantId = $bodyParams.tenantId }
    if ($bodyParams.clientId) { $clientId = $bodyParams.clientId }
    if ($bodyParams.clientSecret) { $clientSecret = $bodyParams.clientSecret }
    if ($bodyParams.certificateThumbprint) { $certThumbprint = $bodyParams.certificateThumbprint }
    if ($bodyParams.certificateBase64) { $certBase64 = $bodyParams.certificateBase64 }
    if ($bodyParams.certificatePassword) { $certPassword = $bodyParams.certificatePassword }
    if ($bodyParams.spoUrl) { $spoUrl = $bodyParams.spoUrl }
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

# Validate spoUrl format
if ($spoUrl -notmatch '^https://[a-zA-Z0-9\-]+\.sharepoint\.com') {
    Push-OutputBinding -Name Response -Value (New-ErrorResponse `
        -StatusCode ([HttpStatusCode]::BadRequest) `
        -ErrorCode "INVALID_SPO_URL" `
        -Message "spoUrl must be a valid SharePoint Online URL." `
        -Details "Expected format: https://contoso.sharepoint.com or https://contoso-admin.sharepoint.com. Received: $spoUrl")
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

try {
    # Determine the target audience scope (assuming SharePoint from spoUrl)
    $uri = [System.Uri]::new($spoUrl)
    $scope = "https://$($uri.Host)/.default"
    
    $tokenEndpoint = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $body = @{
        client_id  = $clientId
        scope      = $scope
        grant_type = "client_credentials"
    }

    if ($certBase64 -or $certThumbprint) {
        Write-Host "Using Certificate-Based Authentication (JWT Signing)"
        
        # 1. Load Certificate
        $cert = $null
        if ($certBase64) {
            $bytes = [Convert]::FromBase64String($certBase64)
            
            # Default passwords to try if one wasn't explicitly provided
            $passwordsToTry = @($certPassword, "", "ChangeMe123!") | Where-Object { $null -ne $_ } | Select-Object -Unique
            
            foreach ($pwd in $passwordsToTry) {
                try {
                    $cert = [X509Certificate2]::new($bytes, $pwd, [X509KeyStorageFlags]::Exportable)
                    break # Successfully loaded
                } catch {
                    # Continue trying other passwords
                }
            }
            
            if (-not $cert) {
                Push-OutputBinding -Name Response -Value (New-ErrorResponse `
                    -StatusCode ([HttpStatusCode]::BadRequest) `
                    -ErrorCode "CERTIFICATE_LOAD_FAILED" `
                    -Message "Failed to load certificate from Base64. Ensure the PFX is valid and the password is correct." `
                    -Details "If your PFX has a password, include 'certificatePassword' in the request body. The Base64 string must be a PFX (not a .cer or .pem).")
                return
            }
        } else {
            $cert = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $certThumbprint }
            if (-not $cert) {
                $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $certThumbprint }
            }
        }

        if (-not $cert) {
            Push-OutputBinding -Name Response -Value (New-ErrorResponse `
                -StatusCode ([HttpStatusCode]::BadRequest) `
                -ErrorCode "CERTIFICATE_NOT_FOUND" `
                -Message "Certificate with thumbprint '$certThumbprint' not found in CurrentUser\My or LocalMachine\My." `
                -Details "For containerized deployments, use certificateBase64 (Base64-encoded PFX) instead of thumbprint.")
            return
        }

        if (-not $cert.HasPrivateKey) {
            Push-OutputBinding -Name Response -Value (New-ErrorResponse `
                -StatusCode ([HttpStatusCode]::BadRequest) `
                -ErrorCode "CERTIFICATE_NO_PRIVATE_KEY" `
                -Message "Certificate does not contain a private key." `
                -Details "You must provide a PFX file (which includes the private key), not a .cer file (which is public key only). Re-export using: Export-PfxCertificate -Cert \$cert -FilePath cert.pfx -Password \$securePassword")
            return
        }

        # 2. Build x5t
        $actualThumbprint = $cert.Thumbprint
        $thumbprintBytes = [byte[]]::new($actualThumbprint.Length / 2)
        for ($i = 0; $i -lt $actualThumbprint.Length; $i += 2) {
            $thumbprintBytes[$i / 2] = [Convert]::ToByte($actualThumbprint.Substring($i, 2), 16)
        }
        $x5t = ConvertTo-Base64UrlString -Bytes $thumbprintBytes

        # 3. Build JWT
        $header = @{
            alg = "RS256"
            typ = "JWT"
            x5t = $x5t
        } | ConvertTo-Json -Compress

        $now = Get-UnixTimestamp
        $payload = @{
            aud = $tokenEndpoint
            iss = $clientId
            sub = $clientId
            jti = [guid]::NewGuid().ToString()
            nbf = $now
            exp = $now + 300
            iat = $now
        } | ConvertTo-Json -Compress

        $headerB64 = ConvertTo-Base64UrlString -Bytes ([System.Text.Encoding]::UTF8.GetBytes($header))
        $payloadB64 = ConvertTo-Base64UrlString -Bytes ([System.Text.Encoding]::UTF8.GetBytes($payload))
        $signingInput = "$headerB64.$payloadB64"
        $signingInputBytes = [System.Text.Encoding]::UTF8.GetBytes($signingInput)

        # 4. Sign JWT (4-method fallback chain)
        $signatureBytes = $null

        # Method 1: CNG via GetRSAPrivateKey
        try {
            $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
            if ($rsa) {
                $signatureBytes = $rsa.SignData($signingInputBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            }
        } catch { }

        # Method 2: Export + reimport with CNG
        if (-not $signatureBytes) {
            try {
                $oldRsa = $cert.PrivateKey
                $params = $oldRsa.ExportParameters($true)
                $cngRsa = [System.Security.Cryptography.RSA]::Create()
                $cngRsa.ImportParameters($params)
                $signatureBytes = $cngRsa.SignData($signingInputBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            } catch { }
        }

        # Method 3: Enhanced CSP
        if (-not $signatureBytes) {
            try {
                $oldRsa = $cert.PrivateKey
                $csp = New-Object System.Security.Cryptography.CspParameters
                $csp.ProviderType = 24
                $csp.KeyContainerName = $oldRsa.CspKeyContainerInfo.KeyContainerName
                $csp.KeyNumber = [int]$oldRsa.CspKeyContainerInfo.KeyNumber
                if ($oldRsa.CspKeyContainerInfo.MachineKeyStore) { $csp.Flags = [System.Security.Cryptography.CspProviderFlags]::UseMachineKeyStore }
                $enhancedRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider($csp)
                $sha256 = [System.Security.Cryptography.SHA256]::Create()
                $hash = $sha256.ComputeHash($signingInputBytes)
                $signatureBytes = $enhancedRsa.SignHash($hash, [System.Security.Cryptography.CryptoConfig]::MapNameToOID("SHA256"))
            } catch { }
        }

        # Method 4: Manual OID
        if (-not $signatureBytes) {
            $oldRsa = $cert.PrivateKey
            $csp = New-Object System.Security.Cryptography.CspParameters
            $csp.ProviderType = 24
            $csp.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
            $csp.KeyContainerName = $oldRsa.CspKeyContainerInfo.KeyContainerName
            $csp.KeyNumber = [int]$oldRsa.CspKeyContainerInfo.KeyNumber
            if ($oldRsa.CspKeyContainerInfo.MachineKeyStore) { $csp.Flags = [System.Security.Cryptography.CspProviderFlags]::UseMachineKeyStore }
            $enhancedRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider($csp)
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $hash = $sha256.ComputeHash($signingInputBytes)
            $signatureBytes = $enhancedRsa.SignHash($hash, "2.16.840.1.101.3.4.2.1")
        }

        if (-not $signatureBytes) {
            Push-OutputBinding -Name Response -Value (New-ErrorResponse `
                -StatusCode ([HttpStatusCode]::InternalServerError) `
                -ErrorCode "JWT_SIGNING_FAILED" `
                -Message "All 4 JWT signing methods failed." `
                -Details "Ensure the certificate uses RSA 2048+ with SHA256. ECDSA and DSA certificates are not supported. Re-generate with: New-SelfSignedCertificate -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256")
            return
        }

        $signatureB64 = ConvertTo-Base64UrlString -Bytes $signatureBytes
        $clientAssertion = "$signingInput.$signatureB64"

        $body.client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        $body.client_assertion = $clientAssertion
    } else {
        Write-Host "Using Client Secret Authentication"
        $body.client_secret = $clientSecret
    }

    # Request the access token
    Write-Host "Retrieving Access Token from OAuth endpoint..."
    $response = Invoke-RestMethod -Uri $tokenEndpoint -Method POST -Body $body -ContentType "application/x-www-form-urlencoded"
    
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = @{
            success      = $true
            access_token = $response.access_token
            token_type   = $response.token_type
            expires_in   = $response.expires_in
            scope        = $scope
        }
        ContentType = "application/json"
    })
} catch {
    Write-Error "Failed to generate token: $_"
    Push-OutputBinding -Name Response -Value (New-ErrorResponse `
        -StatusCode ([HttpStatusCode]::InternalServerError) `
        -ErrorCode "TOKEN_GENERATION_FAILED" `
        -Message "Failed to generate access token." `
        -Details $_.Exception.Message)
}
