# Azure Functions profile.ps1
# This runs on worker startup.

if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity
}
