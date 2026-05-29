# Azure Functions PowerShell Container App Walkthrough

I've built the requested Azure Functions project using PowerShell, packaged as a Docker container app to ensure that your `PnP.PowerShell` modules persist across cold starts. I've also provided the Infrastructure-as-Code files to deploy it to Azure!

## What was built

1. **Dockerfile**: Extending `mcr.microsoft.com/azure-functions/powershell:4-powershell7.4`, the Dockerfile explicitly sets up and installs the **absolute latest** `PnP.PowerShell` module globally. This ensures the modules are baked into the container image, leading to fast function execution without initialization delays.
2. **Azure Function Config**: Disabled `"managedDependency"` in `host.json` since dependencies are handled in the Dockerfile.
3. **GenerateToken Function**: An HTTP-triggered PowerShell function that connects to your environment using Service Principal permissions.

## Infrastructure as Code & Deployment

Inside the `deploy` folder, you will find two files to provision your environment in Azure:

### 1. `deploy/Create-EnterpriseApp.ps1`
Use this script to create your multi-tenant App Registration and generate the certificate credentials. 
```powershell
# Run the script locally
.\deploy\Create-EnterpriseApp.ps1
```
*It will output your `ClientId`, `TenantId`, and a massive `Base64` string representing the PFX certificate. Save these!*

### 2. `deploy/main.bicep`
This template spins up your Log Analytics Workspace, Azure Key Vault, and Azure Container App Environment. It automatically wires up the Container App's Managed Identity to the Key Vault.

```bash
# Push the docker image to a registry (like ACR or Docker Hub)
docker build -t yourregistry.azurecr.io/pwshspcba:v1 .
docker push yourregistry.azurecr.io/pwshspcba:v1

# Deploy the infrastructure
az deployment group create --resource-group YourResourceGroup --template-file deploy/main.bicep \
  --parameters clientId="YOUR_CLIENT_ID" \
               tenantId="YOUR_TENANT_ID" \
               spoUrl="https://yourtenant.sharepoint.com" \
               certificateBase64="THAT_MASSIVE_BASE64_STRING_FROM_THE_SCRIPT" \
               containerImage="yourregistry.azurecr.io/pwshspcba:v1"
```

## Authentication Inside the Container

The Bicep template provisions the Container App and securely stores the Base64 certificate inside the Key Vault. It then maps that Key Vault Secret to the `$env:CERTIFICATE_BASE64` variable inside the Container App. 

At runtime, the script inside `run.ps1` decodes this variable to a temporary file, uses it to run `Connect-PnPOnline`, retrieves your SharePoint access token, and then instantly deletes the temporary file from the container's disk!

## Local Verification

If you just want to test the token generation locally without Azure:

```bash
docker build -t pwsh-sp-cba .

docker run -p 8080:80 \
  -e AzureWebJobsScriptRoot=/home/site/wwwroot \
  -e TENANT_ID="your-tenant-id" \
  -e CLIENT_ID="your-client-id" \
  -e CERTIFICATE_BASE64="your-base64-certificate-string" \
  -e SPO_URL="https://yourtenant.sharepoint.com" \
  pwsh-sp-cba
```

Send an HTTP POST request to `http://localhost:8080/api/GenerateToken` and you will receive your token!
