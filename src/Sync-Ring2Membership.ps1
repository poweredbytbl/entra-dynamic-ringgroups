<#
.SYNOPSIS
Reconciles an assigned Entra ID Ring 2 group from an eligibility group while
excluding direct members of Rings 0, 1, and 3.

.DESCRIPTION
Use as an Azure Automation PowerShell 7.2 runbook with the system-assigned
managed identity. Requires the Microsoft.Graph.Authentication module and the
Microsoft Graph application permission GroupMember.ReadWrite.All.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$EligibilityGroupId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$Ring0GroupId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$Ring1GroupId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$Ring2GroupId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$Ring3GroupId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DirectUserIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$GroupId
    )

    # The type cast returns user objects only; no nested-group expansion occurs.
    $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members/microsoft.graph.user?`$select=id"
    $ids = [System.Collections.Generic.List[string]]::new()

    do {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
        foreach ($member in @($page.value)) {
            if ($null -ne $member.id) {
                $ids.Add([string]$member.id)
            }
        }
        $nextLinkProperty = $page.PSObject.Properties['@odata.nextLink']
        $uri = if ($null -ne $nextLinkProperty) { [string]$nextLinkProperty.Value } else { $null }
    } while (-not [string]::IsNullOrWhiteSpace($uri))

    return $ids
}

function New-StringSet {
    [CmdletBinding()]
    param()

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Write-Output -NoEnumerate $set
}

function Invoke-MembershipBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Requests
    )

    # Microsoft Graph JSON batching supports a maximum of 20 individual requests.
    for ($offset = 0; $offset -lt $Requests.Count; $offset += 20) {
        $end = [Math]::Min($offset + 20, $Requests.Count)
        $chunk = @($Requests[$offset..($end - 1)])
        $body = @{ requests = $chunk } | ConvertTo-Json -Depth 8 -Compress
        $response = Invoke-MgGraphRequest `
            -Method POST `
            -Uri 'https://graph.microsoft.com/v1.0/$batch' `
            -Body $body `
            -ContentType 'application/json' `
            -OutputType PSObject

        $failed = @($response.responses | Where-Object { $_.status -lt 200 -or $_.status -ge 300 })
        if ($failed.Count -gt 0) {
            $details = ($failed | ForEach-Object { "request $($_.id): HTTP $($_.status)" }) -join '; '
            throw "One or more Graph membership updates failed. $details"
        }
    }
}

$graphSessionOpened = $false

try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Connect-MgGraph -Identity -NoWelcome
    $graphSessionOpened = $true

    $eligible = New-StringSet
    foreach ($id in Get-DirectUserIds -GroupId $EligibilityGroupId) {
        [void]$eligible.Add($id)
    }

    $excluded = New-StringSet
    foreach ($groupId in @($Ring0GroupId, $Ring1GroupId, $Ring3GroupId)) {
        foreach ($id in Get-DirectUserIds -GroupId $groupId) {
            [void]$excluded.Add($id)
        }
    }

    $currentRing2 = New-StringSet
    foreach ($id in Get-DirectUserIds -GroupId $Ring2GroupId) {
        [void]$currentRing2.Add($id)
    }

    $desiredRing2 = New-StringSet
    foreach ($id in $eligible) {
        if (-not $excluded.Contains($id)) {
            [void]$desiredRing2.Add($id)
        }
    }

    $addIds = @($desiredRing2.Where({ -not $currentRing2.Contains($_) }) | Sort-Object)
    $removeIds = @($currentRing2.Where({ -not $desiredRing2.Contains($_) }) | Sort-Object)

    Write-Output ("Eligibility={0}; Excluded={1}; CurrentRing2={2}; DesiredRing2={3}; Add={4}; Remove={5}" -f `
        $eligible.Count, $excluded.Count, $currentRing2.Count, $desiredRing2.Count, $addIds.Count, $removeIds.Count)

    if ($WhatIfPreference) {
        if ($addIds.Count -gt 0) { Write-Output "Would add: $($addIds -join ', ')" }
        if ($removeIds.Count -gt 0) { Write-Output "Would remove: $($removeIds -join ', ')" }
        return
    }

    $addRequests = @(
        foreach ($id in $addIds) {
            @{
                id      = [guid]::NewGuid().Guid
                method  = 'POST'
                url     = "groups/$Ring2GroupId/members/`$ref"
                headers = @{ 'Content-Type' = 'application/json' }
                body    = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$id" }
            }
        }
    )
    $removeRequests = @(
        foreach ($id in $removeIds) {
            @{
                id     = [guid]::NewGuid().Guid
                method = 'DELETE'
                url    = "groups/$Ring2GroupId/members/$id/`$ref"
            }
        }
    )

    if ($addRequests.Count -gt 0) {
        Invoke-MembershipBatch -Requests $addRequests
    }
    if ($removeRequests.Count -gt 0) {
        Invoke-MembershipBatch -Requests $removeRequests
    }

    Write-Output 'Ring 2 membership reconciliation completed successfully.'
}
finally {
    if ($graphSessionOpened -and (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue)) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}
