# To enable ssh & remote debugging on app service change the base image to the one below
# FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4-appservice
FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true

# Pre-install PnP.PowerShell module so it persists and doesn't download on cold start
# Skip publisher check and trust repo to avoid prompts during build
RUN pwsh -Command "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
                   Install-Module -Name PnP.PowerShell -Force -Scope AllUsers -AllowClobber"

COPY . /home/site/wwwroot
