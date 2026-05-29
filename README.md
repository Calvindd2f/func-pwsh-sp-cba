[![Docker Image CI](https://github.com/Calvindd2f/func-pwsh-sp-cba/actions/workflows/docker-image.yml/badge.svg)](https://github.com/Calvindd2f/func-pwsh-sp-cba/actions/workflows/docker-image.yml)

# Azure Functions Container App
**PowerShell JWT Token Generation & Ad-Hoc PnP Script Execution**

## Overview
This project is a containerized Azure Functions app designed to execute PowerShell scripts against SharePoint Online (SPO) and Microsoft Graph using Service Principal authentication. By utilizing Docker, we ensure that the `PnP.PowerShell` modules are baked into the image, completely eliminating cold-start installation penalties.

## Core Features
* **Robust Certificate-Based Authentication (CBA)**: Support for Service Principal authentication using Client Secrets or Certificates. Includes advanced manual JWT (JSON Web Token) construction and CNG/SHA256 signing for maximum compatibility.
* **Ad-Hoc Script Execution**: Execute dynamic, on-the-fly `PnP.PowerShell` script blocks submitted via HTTP payloads securely.
* **Infrastructure as Code**: Complete with Bicep templates for deploying Azure Container Apps, Log Analytics, and Key Vault (with automated RBAC mappings for Managed Identity).

---

## API Endpoints

### `POST /api/GenerateToken`
Generates an OAuth 2.0 Access Token for SharePoint Online using a Service Principal. If a certificate is provided, it manually constructs and signs a JWT assertion to authenticate with the Microsoft Identity platform.

**Example Request Body:**
```json
{
  "tenantId": "your-tenant-id",
  "clientId": "your-client-id",
  "certificateBase64": "MIIJ+wIBAzCCCbg...",
  "spoUrl": "https://yourtenant.sharepoint.com"
}
```

### `POST /api/InvokeScript`
Establishes a `Connect-PnPOnline` session using the provided Service Principal credentials, then executes arbitrary PowerShell code passed in the request.

**Example Request Body:**
```json
{
  "tenantId": "your-tenant-id",
  "clientId": "your-client-id",
  "certificateBase64": "MIIJ+wIBAzCCCbg...",
  "spoUrl": "https://yourtenant.sharepoint.com",
  "script": "Get-PnPWeb | Select Title, Url"
}
```

---

## Infrastructure & Deployment
The `deploy` folder contains everything needed to provision this architecture in Azure.

### 1. Create Entra ID Application
Run the Graph PowerShell script locally to create a Multi-Tenant App Registration and generate a self-signed certificate.

```powershell
.\deploy\Create-EnterpriseApp.ps1
```
*Save the outputted `ClientId`, `TenantId`, and Base64 Certificate string.*

### 2. Deploy Azure Resources
Use the Bicep template to spin up the Container App environment and Key Vault.

```bash
az deployment group create \
  --resource-group YourResourceGroup \
  --template-file deploy/main.bicep \
  --parameters clientId="CLIENT_ID" \
               tenantId="TENANT_ID" \
               spoUrl="https://tenant.sharepoint.com" \
               certificateBase64="BASE64_CERT_STRING"
```

---

## Local Development
To test the containerized functions locally using Docker:

```bash
# Build the image
docker build -t pwsh-sp-cba .

# Run the container
docker run -p 8080:80 \
  -e AzureWebJobsScriptRoot=/home/site/wwwroot \
  -e TENANT_ID="your-tenant-id" \
  -e CLIENT_ID="your-client-id" \
  -e CERTIFICATE_BASE64="base64-string" \
  -e SPO_URL="https://tenant.sharepoint.com" \
  pwsh-sp-cba
```
