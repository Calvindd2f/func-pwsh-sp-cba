#!/bin/bash
# =============================================================================
# SPO PowerShell API — cURL Examples
# =============================================================================
# Replace these variables with your actual values before running.
# =============================================================================

API_URL="http://localhost:8080"
# For Azure deployment, use:
# API_URL="https://your-app.azurecontainerapps.io"
# FUNCTION_KEY="your-function-key"
# Append ?code=$FUNCTION_KEY to URLs for Azure deployment

TENANT_ID="your-tenant-id"
CLIENT_ID="your-client-id"
CERT_BASE64="your-base64-pfx-string"
SPO_URL="https://contoso.sharepoint.com"

# =============================================================================
# 1. Health Check (no auth required)
# =============================================================================
echo "=== Health Check ==="
curl -s "$API_URL/api/HealthCheck" | jq .

# =============================================================================
# 2. Generate an Access Token
# =============================================================================
echo ""
echo "=== Generate Token (Certificate Auth) ==="
curl -s -X POST "$API_URL/api/GenerateToken" \
  -H "Content-Type: application/json" \
  -d "{
    \"tenantId\": \"$TENANT_ID\",
    \"clientId\": \"$CLIENT_ID\",
    \"certificateBase64\": \"$CERT_BASE64\",
    \"spoUrl\": \"$SPO_URL\"
  }" | jq .

# =============================================================================
# 3. Generate Token with Client Secret (alternative auth)
# =============================================================================
echo ""
echo "=== Generate Token (Client Secret Auth) ==="
curl -s -X POST "$API_URL/api/GenerateToken" \
  -H "Content-Type: application/json" \
  -d "{
    \"tenantId\": \"$TENANT_ID\",
    \"clientId\": \"$CLIENT_ID\",
    \"clientSecret\": \"your-client-secret\",
    \"spoUrl\": \"$SPO_URL\"
  }" | jq .

# =============================================================================
# 4. Run a Simple PnP Script
# =============================================================================
echo ""
echo "=== Get Web Info ==="
curl -s -X POST "$API_URL/api/InvokeScript" \
  -H "Content-Type: application/json" \
  -d "{
    \"tenantId\": \"$TENANT_ID\",
    \"clientId\": \"$CLIENT_ID\",
    \"certificateBase64\": \"$CERT_BASE64\",
    \"spoUrl\": \"$SPO_URL\",
    \"script\": \"Get-PnPWeb | Select-Object Title, Url, Created | ConvertTo-Json\"
  }" | jq .

# =============================================================================
# 5. List All Site Collections
# =============================================================================
echo ""
echo "=== List All Sites ==="
curl -s -X POST "$API_URL/api/InvokeScript" \
  -H "Content-Type: application/json" \
  -d "{
    \"tenantId\": \"$TENANT_ID\",
    \"clientId\": \"$CLIENT_ID\",
    \"certificateBase64\": \"$CERT_BASE64\",
    \"spoUrl\": \"$SPO_URL\",
    \"script\": \"Get-PnPTenantSite | Select-Object Url, Title, Template, StorageUsageCurrent | ConvertTo-Json\"
  }" | jq .

# =============================================================================
# 6. Get All Lists in a Site
# =============================================================================
echo ""
echo "=== Get Lists ==="
curl -s -X POST "$API_URL/api/InvokeScript" \
  -H "Content-Type: application/json" \
  -d "{
    \"tenantId\": \"$TENANT_ID\",
    \"clientId\": \"$CLIENT_ID\",
    \"certificateBase64\": \"$CERT_BASE64\",
    \"spoUrl\": \"$SPO_URL\",
    \"script\": \"Get-PnPList | Where-Object { -not \\\$_.Hidden } | Select-Object Title, ItemCount, Created | ConvertTo-Json\"
  }" | jq .

# =============================================================================
# 7. Permission Audit
# =============================================================================
echo ""
echo "=== Permission Audit ==="
curl -s -X POST "$API_URL/api/InvokeScript" \
  -H "Content-Type: application/json" \
  -d "{
    \"tenantId\": \"$TENANT_ID\",
    \"clientId\": \"$CLIENT_ID\",
    \"certificateBase64\": \"$CERT_BASE64\",
    \"spoUrl\": \"$SPO_URL\",
    \"script\": \"Get-PnPSiteCollectionAdmin | Select-Object Title, Email, LoginName | ConvertTo-Json\"
  }" | jq .

# =============================================================================
# 8. Storage Report
# =============================================================================
echo ""
echo "=== Storage Report ==="
curl -s -X POST "$API_URL/api/InvokeScript" \
  -H "Content-Type: application/json" \
  -d "{
    \"tenantId\": \"$TENANT_ID\",
    \"clientId\": \"$CLIENT_ID\",
    \"certificateBase64\": \"$CERT_BASE64\",
    \"spoUrl\": \"$SPO_URL\",
    \"script\": \"Get-PnPTenantSite -Detailed | Select-Object Url, @{N='UsageMB';E={\\\$_.StorageUsageCurrent}}, @{N='QuotaMB';E={\\\$_.StorageMaximumLevel}} | Sort-Object UsageMB -Descending | Select-Object -First 10 | ConvertTo-Json\"
  }" | jq .
