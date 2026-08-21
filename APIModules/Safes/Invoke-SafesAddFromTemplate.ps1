#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Safe From Template'
    Category         = 'Safes'
    Action           = 'AddFromTemplate'
    Description      = 'Create a new safe by copying settings and non-role-group members from the profile template safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';    Required = $true;  Description = 'Unique name for the new safe (max 28 chars).' }
        @{ Column = 'Description'; Required = $false; Description = 'Description for the new safe. Never copied from the template safe.' }
    )
    Priority         = 15
    Version          = '1.2.0'
}

function Get-SafesAddFromTemplateInput {
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

    $templateSafe = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Template_Safe']) {
        "$($script:ActiveProfile.Role_Template_Safe)"
    } else { '' }

    Write-Host '  New Safe From Template  (press Enter to accept each default)' -ForegroundColor DarkGray
    Write-Host "  Template safe: $(if ($templateSafe) { $templateSafe } else { '(not configured on this profile - see Profile Settings)' })" -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Unique safe name (max 28 chars).'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'Description for the new safe. Never copied from the template safe.'

    return @{
        SafeName    = $safeName
        Description = $description
    }
}

function Invoke-SafesAddFromTemplate {
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

    # Validate required field SafeName
    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }
    if (-not $safeName) {
        $msg = 'SafeName is required and cannot be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $description = if ($InputData['Description']) { "$($InputData['Description'])".Trim() } else { '' }

    # Resolve the template safe name and role-group prefix from the active profile.
    # Both are required - see Docs\Add-Safe-From-Template-Design.md, Decision D4.
    $templateSafe = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Template_Safe']) {
        "$($script:ActiveProfile.Role_Template_Safe)".Trim()
    } else { '' }
    $rolePrefix = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Group_Prefix']) {
        "$($script:ActiveProfile.Role_Group_Prefix)".Trim()
    } else { '' }

    if (-not $templateSafe) {
        $msg = 'Role_Template_Safe is not configured on the active profile. Set it via Profile Settings before using Add Safe From Template.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if (-not $rolePrefix) {
        $msg = 'Role_Group_Prefix is not configured on the active profile. Set it via Profile Settings before using Add Safe From Template.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedTemplateSafe = [Uri]::EscapeDataString($templateSafe)

    # Step 1: read the template safe's settings.
    Write-CyberArkLog -Level 'INFO'  -Message "Reading template safe '$templateSafe' settings."
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedTemplateSafe"

    $templateSafeResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedTemplateSafe" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $templateSafeResponse.IsSuccess) {
        $msg = "Template safe '$templateSafe' could not be read (HTTP $($templateSafeResponse.StatusCode)): $($templateSafeResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $templateSafeResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($templateSafeResponse.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $templateSafeData = $templateSafeResponse.Data

    # Step 2: read the template safe's member list.
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedTemplateSafe/Members"

    $templateMembersResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedTemplateSafe/Members" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $templateMembersResponse.IsSuccess) {
        $msg = "Template safe '$templateSafe' members could not be read (HTTP $($templateMembersResponse.StatusCode)): $($templateMembersResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $templateMembersResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($templateMembersResponse.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    [array]$templateMembers = if ($templateMembersResponse.Data -and $templateMembersResponse.Data.PSObject.Properties['value']) {
        @($templateMembersResponse.Data.value)
    } else { @() }

    # Step 3: exclude role groups - any member whose name starts with Role_Group_Prefix
    # (case-insensitive), regardless of memberType - and exclude any member whose name
    # exactly matches (case-insensitive) an entry in the global $script:ExcludedTemplateMemberNames
    # list (defined in Driver.ps1; shared by any Safes/SafeMembers module that reuses it).
    # Everything else is copied.
    [array]$excludedNames = if ($script:ExcludedTemplateMemberNames) { @($script:ExcludedTemplateMemberNames) } else { @() }

    [array]$membersToCopy = @($templateMembers | Where-Object {
        $memberName = if ($_.PSObject.Properties['memberName']) { "$($_.memberName)" } else { '' }
        if (-not $memberName) { return $false }
        if ($memberName.StartsWith($rolePrefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        foreach ($excluded in $excludedNames) {
            if ($memberName.Equals("$excluded", [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    })

    Write-CyberArkLog -Level 'INFO' -Message "Template safe '$templateSafe' has $($templateMembers.Count) member(s); $($membersToCopy.Count) will be copied after excluding role groups matching prefix '$rolePrefix' and $($excludedNames.Count) globally excluded name(s)."

    # Build the new safe's request body. SafeName/Description are always fresh input;
    # every other setting is copied from the template safe (Decision D1). Field casing
    # matches Invoke-SafesAdd.ps1 - POST /API/Safes expects PascalCase, but the GET
    # response above returns camelCase (a documented quirk of this endpoint).
    # OLACEnabled is intentionally never read or sent - it is not a supported field for
    # this module. NumberOfVersionsRetention and NumberOfDaysRetention are mutually
    # exclusive on this API - only one may be sent; Days wins when the template's value
    # is greater than 0, otherwise Versions is sent.
    $templateVersionsRetention = if ($templateSafeData.PSObject.Properties['numberOfVersionsRetention']) { [int]$templateSafeData.numberOfVersionsRetention } else { 5 }
    $templateDaysRetention     = if ($templateSafeData.PSObject.Properties['numberOfDaysRetention'])     { [int]$templateSafeData.numberOfDaysRetention }     else { 0 }

    $safeBody = @{
        SafeName         = $safeName
        Description      = $description
        Location         = if ($templateSafeData.PSObject.Properties['location'])         { $templateSafeData.location }                else { '\' }
        ManagingCPM      = if ($templateSafeData.PSObject.Properties['managingCPM'])      { $templateSafeData.managingCPM }              else { '' }
        AutoPurgeEnabled = if ($templateSafeData.PSObject.Properties['autoPurgeEnabled'])  { [bool]$templateSafeData.autoPurgeEnabled }   else { $false }
    }
    if ($templateDaysRetention -gt 0) {
        $safeBody['NumberOfDaysRetention'] = $templateDaysRetention
    } else {
        $safeBody['NumberOfVersionsRetention'] = $templateVersionsRetention
    }

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "[WhatIf] Would POST /API/Safes for '$safeName', then copy $($membersToCopy.Count) member(s) from template '$templateSafe'."

        $result.Results.Add([PSCustomObject]@{
            ItemType         = 'Safe'
            SafeName         = $safeName
            Description      = $safeBody.Description
            Location         = $safeBody.Location
            ManagingCPM      = $safeBody.ManagingCPM
            VersionRetention = $safeBody.NumberOfVersionsRetention
            DayRetention     = $safeBody.NumberOfDaysRetention
            AutoPurge        = $safeBody.AutoPurgeEnabled
            MemberName       = ''
            MemberType       = ''
        })
        $result.Successes++
        $result.ItemsProcessed++

        foreach ($member in $membersToCopy) {
            $memberName = if ($member.PSObject.Properties['memberName']) { "$($member.memberName)" } else { '' }
            $memberType = if ($member.PSObject.Properties['memberType']) { "$($member.memberType)" } else { '' }
            $result.Results.Add([PSCustomObject]@{
                ItemType         = 'Member'
                SafeName         = $safeName
                Description      = ''
                Location         = ''
                ManagingCPM      = ''
                VersionRetention = $null
                DayRetention     = $null
                AutoPurge        = $null
                MemberName       = $memberName
                MemberType       = $memberType
            })
            $result.Successes++
            $result.ItemsProcessed++
        }

        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # Step 4: create the new safe.
    Write-CyberArkLog -Level 'INFO'  -Message "Creating safe '$safeName' from template '$templateSafe'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes | SafeName='$safeName'"

    $safeResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint '/API/Safes' `
        -Body     $safeBody

    if (-not $safeResponse.IsSuccess) {
        $msg = "Add safe failed (HTTP $($safeResponse.StatusCode)): $($safeResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $safeResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($safeResponse.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $createdSafe = if ($safeResponse.Data) { $safeResponse.Data } else { $null }

    $result.Results.Add([PSCustomObject]@{
        ItemType         = 'Safe'
        SafeName         = if ($createdSafe -and $createdSafe.PSObject.Properties['safeName'])                  { $createdSafe.safeName }                  else { $safeName }
        Description      = if ($createdSafe -and $createdSafe.PSObject.Properties['description'])               { $createdSafe.description }               else { $safeBody.Description }
        Location         = if ($createdSafe -and $createdSafe.PSObject.Properties['location'])                  { $createdSafe.location }                  else { $safeBody.Location }
        ManagingCPM      = if ($createdSafe -and $createdSafe.PSObject.Properties['managingCPM'])              { $createdSafe.managingCPM }              else { $safeBody.ManagingCPM }
        VersionRetention = if ($createdSafe -and $createdSafe.PSObject.Properties['numberOfVersionsRetention']) { $createdSafe.numberOfVersionsRetention } else { $safeBody.NumberOfVersionsRetention }
        DayRetention     = if ($createdSafe -and $createdSafe.PSObject.Properties['numberOfDaysRetention'])     { $createdSafe.numberOfDaysRetention }     else { $safeBody.NumberOfDaysRetention }
        AutoPurge        = if ($createdSafe)                                                                    { $createdSafe.autoPurgeEnabled }          else { $safeBody.AutoPurgeEnabled }
        MemberName       = ''
        MemberType       = ''
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe '$safeName' created. Copying $($membersToCopy.Count) member(s) from template."

    # Step 5: copy each retained member onto the new safe.
    $encodedNewSafe = [Uri]::EscapeDataString($safeName)

    foreach ($member in $membersToCopy) {
        $memberName = if ($member.PSObject.Properties['memberName']) { "$($member.memberName)" } else { '' }
        if (-not $memberName) { continue }
        $memberType  = if ($member.PSObject.Properties['memberType'])  { "$($member.memberType)" } else { '' }
        $permissions = if ($member.PSObject.Properties['permissions'] -and $member.permissions) { $member.permissions } else { @{} }

        # membershipExpirationDate is never copied from the template (Decision D3).
        $memberBody = @{
            memberName               = $memberName
            membershipExpirationDate = $null
            permissions              = $permissions
        }
        if ($memberType) { $memberBody['memberType'] = $memberType }

        Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes/$encodedNewSafe/Members | MemberName='$memberName'"

        $memberResponse = Invoke-CyberArkAPI `
            -Token    $Token `
            -Method   'POST' `
            -Endpoint "/API/Safes/$encodedNewSafe/Members" `
            -Body     $memberBody

        if (-not $memberResponse.IsSuccess) {
            $msg = "Add member '$memberName' to safe '$safeName' failed (HTTP $($memberResponse.StatusCode)): $($memberResponse.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = @{ SafeName = $safeName; MemberName = $memberName }
                ErrorMessage = $msg
                ErrorDetails = $memberResponse.ErrorDetails
            })
            $result.Failures++
            $result.ItemsProcessed++
            if ($memberResponse.StatusCode -in @(401, 0)) {
                $result.IsFatal = $true
                Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
                return $result
            }
            continue
        }

        $addedMember = if ($memberResponse.Data) { $memberResponse.Data } else { $null }

        $result.Results.Add([PSCustomObject]@{
            ItemType         = 'Member'
            SafeName         = $safeName
            Description      = ''
            Location         = ''
            ManagingCPM      = ''
            VersionRetention = $null
            DayRetention     = $null
            AutoPurge        = $null
            OLACEnabled      = $null
            MemberName       = if ($addedMember -and $addedMember.PSObject.Properties['memberName']) { $addedMember.memberName } else { $memberName }
            MemberType       = if ($addedMember -and $addedMember.PSObject.Properties['memberType']) { $addedMember.memberType } else { $memberType }
        })
        $result.Successes++
        $result.ItemsProcessed++
    }

    Write-CyberArkLog -Level 'INFO' -Message "Add Safe From Template complete. Safe '$safeName' created; $($result.Successes - 1) of $($membersToCopy.Count) member(s) copied."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
