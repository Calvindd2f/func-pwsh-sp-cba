# Real-World Use Cases

These are concrete SharePoint Online operations that **require PnP PowerShell or SPO PowerShell** and cannot be done through Microsoft Graph API alone. Each example includes a ready-to-use JSON payload for the `/api/InvokeScript` endpoint.

> **Base request structure**: Every example below assumes you're sending a POST to `/api/InvokeScript` with your `tenantId`, `clientId`, `certificateBase64`, and `spoUrl` alongside the `script` field. Only the `script` and `spoUrl` values are shown for brevity.

---

## 1. Batch Permission Trimming

**Why PnP?** Microsoft Graph has no API for bulk role inheritance changes across site collections. SPO PowerShell is the only way to break/restore inheritance and modify role assignments at scale.

### Audit Unique Permissions Across a Site

```json
{
  "spoUrl": "https://contoso.sharepoint.com/sites/HR",
  "script": "$lists = Get-PnPList -Includes HasUniqueRoleAssignments, RoleAssignments; $results = @(); foreach ($list in $lists) { if ($list.HasUniqueRoleAssignments) { $results += [PSCustomObject]@{ ListTitle = $list.Title; UniquePerms = $true; RoleCount = $list.RoleAssignments.Count } } }; $results | ConvertTo-Json"
}
```

### Remove a Specific User from All Lists

```json
{
  "spoUrl": "https://contoso.sharepoint.com/sites/HR",
  "script": "$user = 'i:0#.f|membership|john@contoso.com'; $lists = Get-PnPList; foreach ($list in $lists) { try { Set-PnPListPermission -Identity $list -User $user -RemoveRole 'Contribute' -ErrorAction SilentlyContinue } catch {} }; Write-Output 'Permission trimming complete'"
}
```

### Reset All Lists to Inherit from Site

```json
{
  "spoUrl": "https://contoso.sharepoint.com/sites/HR",
  "script": "$lists = Get-PnPList -Includes HasUniqueRoleAssignments; $reset = @(); foreach ($list in $lists) { if ($list.HasUniqueRoleAssignments) { Set-PnPList -Identity $list -ResetRoleInheritance; $reset += $list.Title } }; [PSCustomObject]@{ ResetLists = $reset; Count = $reset.Count } | ConvertTo-Json"
}
```

---

## 2. Tenant Search Schema Management

**Why PnP?** Search managed properties at the tenant level can only be created/modified via PowerShell. The Graph Search API is read-only.

### Export All Managed Properties

```json
{
  "spoUrl": "https://contoso-admin.sharepoint.com",
  "script": "Get-PnPSearchConfiguration -Scope Subscription -OutputFormat ManagedPropertyMappings"
}
```

### Create a Custom Managed Property

```json
{
  "spoUrl": "https://contoso-admin.sharepoint.com",
  "script": "$xml = Get-PnPSearchConfiguration -Scope Subscription; Set-PnPSearchConfiguration -Scope Subscription -Configuration $xml"
}
```

---

## 3. Site Collection Storage Quota Management

**Why SPO PowerShell?** Storage quota management for individual site collections is not available in Microsoft Graph.

### Get Storage Usage Across All Sites

```json
{
  "spoUrl": "https://contoso.sharepoint.com",
  "script": "Get-PnPTenantSite -Detailed | Select-Object Url, StorageUsageCurrent, StorageMaximumLevel, @{N='UsageGB';E={[math]::Round($_.StorageUsageCurrent/1024,2)}}, @{N='QuotaGB';E={[math]::Round($_.StorageMaximumLevel/1024,2)}}, @{N='PercentUsed';E={if($_.StorageMaximumLevel -gt 0){[math]::Round(($_.StorageUsageCurrent/$_.StorageMaximumLevel)*100,1)}else{'N/A'}}} | Sort-Object StorageUsageCurrent -Descending | ConvertTo-Json"
}
```

### Set Storage Quota on a Specific Site

```json
{
  "spoUrl": "https://contoso-admin.sharepoint.com",
  "script": "Set-PnPTenantSite -Identity 'https://contoso.sharepoint.com/sites/Projects' -StorageMaximumLevel 5120 -StorageWarningLevel 4608; Write-Output 'Quota set: 5GB max, 4.5GB warning'"
}
```

---

## 4. Site Provisioning at Scale

**Why PnP?** While Graph can create basic sites, PnP is required for template-based provisioning with full configuration (navigation, content types, columns, views, permissions).

### Provision a Team Site with Template

```json
{
  "spoUrl": "https://contoso.sharepoint.com",
  "script": "$site = New-PnPTenantSite -Title 'Project Alpha' -Url 'https://contoso.sharepoint.com/sites/ProjectAlpha' -Template 'STS#3' -Owner 'admin@contoso.com' -TimeZone 2 -StorageQuota 1024; $site | ConvertTo-Json"
}
```

### Bulk Site Creation from CSV Data

```json
{
  "spoUrl": "https://contoso.sharepoint.com",
  "script": "$sites = @( @{Title='Department A'; Url='DeptA'}, @{Title='Department B'; Url='DeptB'}, @{Title='Department C'; Url='DeptC'} ); $results = @(); foreach ($s in $sites) { try { New-PnPTenantSite -Title $s.Title -Url \"https://contoso.sharepoint.com/sites/$($s.Url)\" -Template 'STS#3' -Owner 'admin@contoso.com' -TimeZone 2 -StorageQuota 1024 -Wait; $results += [PSCustomObject]@{Site=$s.Title; Status='Created'} } catch { $results += [PSCustomObject]@{Site=$s.Title; Status=\"Failed: $_\"} } }; $results | ConvertTo-Json"
}
```

---

## 5. Sharing Link Audit & Cleanup

**Why PnP?** Graph can list sharing links for individual items, but bulk auditing and cleanup across entire site collections requires PnP PowerShell.

### Find All Anonymous Sharing Links

```json
{
  "spoUrl": "https://contoso.sharepoint.com/sites/HR",
  "script": "$lists = Get-PnPList | Where-Object { -not $_.Hidden }; $anonLinks = @(); foreach ($list in $lists) { $items = Get-PnPListItem -List $list -PageSize 500; foreach ($item in $items) { $links = Get-PnPFileSharingLink -Identity $item.FieldValues.FileRef -ErrorAction SilentlyContinue; $anonLinks += $links | Where-Object { $_.Link.Scope -eq 'anonymous' } | ForEach-Object { [PSCustomObject]@{ File = $item.FieldValues.FileRef; LinkUrl = $_.Link.WebUrl; Scope = $_.Link.Scope; Type = $_.Link.Type } } } }; $anonLinks | ConvertTo-Json"
}
```

---

## 6. Hub Site Management

**Why PnP?** Hub site registration and association management is only available through PowerShell.

### List All Hub Sites

```json
{
  "spoUrl": "https://contoso-admin.sharepoint.com",
  "script": "Get-PnPHubSite | Select-Object SiteId, SiteUrl, Title, Description | ConvertTo-Json"
}
```

### Associate a Site to a Hub

```json
{
  "spoUrl": "https://contoso.sharepoint.com",
  "script": "Add-PnPHubSiteAssociation -Site 'https://contoso.sharepoint.com/sites/ProjectAlpha' -HubSite 'https://contoso.sharepoint.com/sites/ProjectsHub'; Write-Output 'Site associated with hub'"
}
```

---

## 7. Compliance & eDiscovery

**Why SPO PowerShell?** Compliance features like in-place holds and audit log operations require SPO admin PowerShell.

### Get Site Compliance Policies

```json
{
  "spoUrl": "https://contoso-admin.sharepoint.com",
  "script": "Get-PnPTenantSite -Detailed | Select-Object Url, LockState, ConditionalAccessPolicy, SharingCapability, DenyAddAndCustomizePages | ConvertTo-Json"
}
```

### Lock/Unlock a Site Collection

```json
{
  "spoUrl": "https://contoso-admin.sharepoint.com",
  "script": "Set-PnPTenantSite -Identity 'https://contoso.sharepoint.com/sites/Legal' -LockState 'ReadOnly'; Write-Output 'Site set to read-only'"
}
```

---

## 8. Content Type & Column Management

**Why PnP?** Tenant-level content type hub operations are only available via PnP PowerShell.

### Export All Site Content Types

```json
{
  "spoUrl": "https://contoso.sharepoint.com/sites/HR",
  "script": "Get-PnPContentType | Select-Object Name, Id, Group, Description | ConvertTo-Json"
}
```

### Add a Site Column

```json
{
  "spoUrl": "https://contoso.sharepoint.com/sites/HR",
  "script": "Add-PnPField -DisplayName 'Project Code' -InternalName 'ProjectCode' -Type Text -Group 'Custom Columns'; Write-Output 'Field created'"
}
```

---

## 9. Site Inventory & Reporting

### Full Tenant Site Inventory

```json
{
  "spoUrl": "https://contoso.sharepoint.com",
  "script": "Get-PnPTenantSite -Detailed | Select-Object Url, Title, Template, Owner, StorageUsageCurrent, LastContentModifiedDate, ConditionalAccessPolicy, SharingCapability, LockState, GroupId | ConvertTo-Json -Depth 3"
}
```

### Find Inactive Sites (No Modifications in 90 Days)

```json
{
  "spoUrl": "https://contoso.sharepoint.com",
  "script": "$cutoff = (Get-Date).AddDays(-90); Get-PnPTenantSite -Detailed | Where-Object { $_.LastContentModifiedDate -lt $cutoff } | Select-Object Url, Title, LastContentModifiedDate, StorageUsageCurrent | Sort-Object LastContentModifiedDate | ConvertTo-Json"
}
```

---

## Tips for Writing Scripts

1. **Always pipe to `ConvertTo-Json`** at the end of your script so the API returns structured data instead of PowerShell formatting
2. **Use `Select-Object`** to limit the output — returning full SharePoint objects will include many internal properties
3. **The PnP connection is available as `$args[0]`** if you need to pass it explicitly to cmdlets
4. **Use `-ErrorAction Stop`** to ensure errors are caught and returned properly by the API
5. **For admin operations**, set `spoUrl` to your admin URL: `https://contoso-admin.sharepoint.com`
