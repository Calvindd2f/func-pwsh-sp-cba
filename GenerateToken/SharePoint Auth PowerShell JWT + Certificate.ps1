# ============================================================================
# SharePoint Certificate Auth Token Generator
# Uses CNG for SHA256 signing - Compatible with CAPI certificates
# ============================================================================

$TenantId = ""
$ClientId = ""
$CertThumbprint = ""
$SharePointTenant = ""

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

# ============================================================================
# MAIN SCRIPT
# ============================================================================
# Load certificate from LocalMachine store
$cert = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $CertThumbprint }

if (-not $cert) {
    $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $CertThumbprint }
}

if (-not $cert) {
    throw "Certificate with thumbprint $CertThumbprint not found"
}

if (-not $cert.HasPrivateKey) {
    throw "Certificate does not have a private key"
}

# Build x5t (thumbprint as base64url)
$thumbprintBytes = [byte[]]::new($CertThumbprint.Length / 2)
for ($i = 0; $i -lt $CertThumbprint.Length; $i += 2) {
    $thumbprintBytes[$i / 2] = [Convert]::ToByte($CertThumbprint.Substring($i, 2), 16)
}
$x5t = ConvertTo-Base64UrlString -Bytes $thumbprintBytes

# JWT Header
$header = @{
    alg = "RS256"
    typ = "JWT"
    x5t = $x5t
} | ConvertTo-Json -Compress

# JWT Payload
$now = Get-UnixTimestamp
$payload = @{
    aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    iss = $ClientId
    sub = $ClientId
    jti = [guid]::NewGuid().ToString()
    nbf = $now
    exp = $now + 300
    iat = $now
} | ConvertTo-Json -Compress

# Encode header and payload
$headerB64 = ConvertTo-Base64UrlString -Bytes ([System.Text.Encoding]::UTF8.GetBytes($header))
$payloadB64 = ConvertTo-Base64UrlString -Bytes ([System.Text.Encoding]::UTF8.GetBytes($payload))
$signingInput = "$headerB64.$payloadB64"
$signingInputBytes = [System.Text.Encoding]::UTF8.GetBytes($signingInput)

# Try to get RSA CNG key (preferred for SHA256)
$rsa = $null
$signatureBytes = $null

# Method 1: Try GetRSAPrivateKey() which returns CNG-capable key (.NET 4.6+)
try {
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if ($rsa) {
        $signatureBytes = $rsa.SignData($signingInputBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
}
catch {
    $rsa = $null
}

# Method 2: If that failed, try to export and reimport with CNG
if (-not $signatureBytes) {
    try {
        # Export the key parameters and create a new CNG-based RSA
        $oldRsa = $cert.PrivateKey
        $params = $oldRsa.ExportParameters($true)

        $cngRsa = [System.Security.Cryptography.RSA]::Create()
        $cngRsa.ImportParameters($params)

        $signatureBytes = $cngRsa.SignData($signingInputBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
    catch {
        # Continue to next method
    }
}

# Method 3: Use RSACryptoServiceProvider with enhanced key
if (-not $signatureBytes) {
    try {
        $oldRsa = $cert.PrivateKey

        # Create new RSACryptoServiceProvider with Microsoft Enhanced RSA and AES Cryptographic Provider
        $csp = New-Object System.Security.Cryptography.CspParameters
        $csp.ProviderType = 24  # PROV_RSA_AES - supports SHA256
        $csp.KeyContainerName = $oldRsa.CspKeyContainerInfo.KeyContainerName
        $csp.KeyNumber = [int]$oldRsa.CspKeyContainerInfo.KeyNumber

        if ($oldRsa.CspKeyContainerInfo.MachineKeyStore) {
            $csp.Flags = [System.Security.Cryptography.CspProviderFlags]::UseMachineKeyStore
        }

        $enhancedRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider($csp)

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hash = $sha256.ComputeHash($signingInputBytes)
        $signatureBytes = $enhancedRsa.SignHash($hash, [System.Security.Cryptography.CryptoConfig]::MapNameToOID("SHA256"))
    }
    catch {
        # Continue to next method
    }
}

# Method 4: Last resort - manual OID
if (-not $signatureBytes) {
    $oldRsa = $cert.PrivateKey

    $csp = New-Object System.Security.Cryptography.CspParameters
    $csp.ProviderType = 24
    $csp.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
    $csp.KeyContainerName = $oldRsa.CspKeyContainerInfo.KeyContainerName
    $csp.KeyNumber = [int]$oldRsa.CspKeyContainerInfo.KeyNumber

    if ($oldRsa.CspKeyContainerInfo.MachineKeyStore) {
        $csp.Flags = [System.Security.Cryptography.CspProviderFlags]::UseMachineKeyStore
    }

    $enhancedRsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider($csp)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha256.ComputeHash($signingInputBytes)

    # Use OID directly: 2.16.840.1.101.3.4.2.1 = SHA256
    $signatureBytes = $enhancedRsa.SignHash($hash, "2.16.840.1.101.3.4.2.1")
}

if (-not $signatureBytes) {
    throw "All signing methods failed"
}

$signatureB64 = ConvertTo-Base64UrlString -Bytes $signatureBytes
$clientAssertion = "$signingInput.$signatureB64"

# Request access token
$tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$scope = "https://$SharePointTenant.sharepoint.com/.default"

$body = @{
    client_id             = $ClientId
    scope                 = $scope
    grant_type            = "client_credentials"
    client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    client_assertion      = $clientAssertion
}

$response = Invoke-RestMethod -Uri $tokenEndpoint -Method POST -Body $body -ContentType "application/x-www-form-urlencoded"
$results = @{
    success      = $true
    access_token = $response.access_token
    token_type   = $response.token_type
    expires_in   = $response.expires_in
    scope        = $scope
} | ConvertTo-Json
$postData = $results | ConvertTo-Json
$postData = [System.Text.Encoding]::UTF8.GetBytes($postData)
Invoke-RestMethod -Method 'Post' -Uri $post_url -Body $postData -ContentType 'application/json; charset=utf-8'