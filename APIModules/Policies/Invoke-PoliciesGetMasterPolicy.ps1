#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Master Policy'
    Category         = 'Policies'
    Action           = 'GetMasterPolicy'
    # Self-Hosted only, matching psPAS's Get-PASMasterPolicy.ps1, which explicitly asserts
    # -SelfHosted and PVWA 14.6+. Confirmed against the CyberArk 14.6 self-hosted Swagger spec's
    # /API/Policies/{policyId} GET, which returns each of the 15 fields below wrapped as
    # { Value: ... } (a Rule[Boolean]/Rule[UInt32] object) - flattened to plain values here.
    Description      = 'Retrieve the Master Policy (Self-Hosted PVWA 14.6+ only), matching psPAS''s Get-PASMasterPolicy.ps1.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'PolicyId'; Required = $false; Description = 'Policy ID to retrieve. Defaults to 1 (the Master Policy).' }
    )
    Priority         = 90
    Version          = '1.0.0'
}

# Every Master Policy field is wrapped as { Value: ... } on the wire - flatten to plain
# values. Guarded against a missing field/wrapper per Lessons-Learned-PowerShell-Pester.md
# Section 27 ($null.PSObject access under Set-StrictMode).
function script:Get-FlatPolicyValue {
    param($Policy, [string]$Field)
    if ($null -eq $Policy -or -not $Policy.PSObject.Properties[$Field]) { return $null }
    $wrapper = $Policy.$Field
    if ($null -eq $wrapper) { return $null }
    if ($wrapper.PSObject.Properties['Value']) { return $wrapper.Value }
    return $wrapper
}

function Get-PoliciesGetMasterPolicyInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt is available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    $policyId = Show-FieldPrompt -Label 'Policy ID' `
        -Default $(if ($Defaults['PolicyId']) { $Defaults['PolicyId'] } else { '1' }) `
        -Description 'Policy ID to retrieve. Leave as 1 for the Master Policy.'

    return @{
        PolicyId = $policyId
    }
}

function Invoke-PoliciesGetMasterPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$InputData,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        ModuleName     = $ModuleMeta.Name
        Category       = $ModuleMeta.Category
        Action         = $ModuleMeta.Action
        ItemsProcessed = 0
        Successes      = 0
        Failures       = 0
        IsFatal        = $false
        Results        = [System.Collections.Generic.List[PSCustomObject]]::new()
        Errors         = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    if (-not $InputData) { $InputData = @{} }

    $policyIdRaw = if ($InputData['PolicyId']) { "$($InputData['PolicyId'])".Trim() } else { '1' }
    $policyId    = 1
    if (-not [int]::TryParse($policyIdRaw, [ref]$policyId)) {
        $msg = "PolicyId '$policyIdRaw' is not a valid integer."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting master policy retrieval for PolicyId=$policyId."
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Policies/$policyId"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Policies/$policyId" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Master policy get failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    $policy = $response.Data

    $fields = @(
        'DualControl', 'MultiLevelApproval', 'OnlyManagersApproval', 'ConfirmersNumber',
        'EnforceExclusiveAccess', 'EnforceOneTimePassword', 'TransparentConnection',
        'AllowViewPassword', 'RequireReason', 'AllowFreeText', 'PasswordChangeDays',
        'PasswordVerificationDays', 'RequireMonitoringAndIsolation', 'RecordActivity',
        'RetentionPeriod'
    )

    $row = [PSCustomObject]@{ PolicyId = $policyId }
    foreach ($field in $fields) {
        $row | Add-Member -NotePropertyName $field -NotePropertyValue (script:Get-FlatPolicyValue -Policy $policy -Field $field)
    }

    $result.Results.Add($row)
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Master policy retrieval complete for PolicyId=$policyId."

    return $result
}
