# Stage 1: Use the official PowerShell image to download the module
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04 AS installer

# Create a directory to hold the downloaded modules
RUN mkdir -p /Modules

# Download PnP.PowerShell so we can copy it into the final image
RUN pwsh -Command "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
                   Save-Module -Name PnP.PowerShell -Path /Modules -Force"

# Stage 2: Build the final Azure Functions image
# (The Azure Functions base image does not contain the 'pwsh' executable, 
# so we must use a multi-stage build to pre-download the module)
FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true

# Copy the pre-downloaded modules from the installer stage into the function app's local Modules directory.
# The Azure Functions PowerShell worker automatically loads modules from the 'Modules' folder in the script root.
COPY --from=installer /Modules /home/site/wwwroot/Modules

COPY . /home/site/wwwroot
