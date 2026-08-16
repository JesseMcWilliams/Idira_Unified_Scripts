#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Export Local Group Members'
    Category         = 'Custom'
    Action           = 'ExportGroupMembersLocal'
    Description      = 'Export all local CyberArk group members, recursively expanding nested groups, with parent/child level and relationship path columns.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $false
    InputSchema      = @()
    Priority         = 82
    Version          = '1.0.0'
}

function Invoke-CustomExportGroupMembersLocal {
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

    $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }

    Write-Host '  Retrieving all CyberArk groups...' -ForegroundColor Cyan
    Write-CyberArkLog -Level 'INFO' -Message 'Export Local Group Members: retrieving group list.'

    $groupsResponse = Invoke-CyberArkAPI `
        -Token     $Token `
        -Method    'GET' `
        -Endpoint  '/API/UserGroups' `
        -IgnoreSSL:$ignoreSSL

    if (-not $groupsResponse.IsSuccess) {
        $msg = "Export Local Group Members: group list failed (HTTP $($groupsResponse.StatusCode)): $($groupsResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $null
            ErrorMessage = $groupsResponse.ErrorMessage
            ErrorDetails = $groupsResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($groupsResponse.StatusCode -in @(401, 0))
        return $result
    }

    $allGroups = if ($groupsResponse.Data -and $groupsResponse.Data.PSObject.Properties['value']) {
        @($groupsResponse.Data.value)
    } else { @() }

    if ($allGroups.Count -eq 0) {
        Write-Host '  No groups found.' -ForegroundColor Yellow
        Write-CyberArkLog -Level 'WARN' -Message 'Export Local Group Members: no groups returned.'
        return $result
    }

    # Build lookup: groupId (string) -> groupName
    # Also build separate sets for local vs LDAP groups
    $groupIdToName = @{}
    $localGroups   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $ldapGroupIds  = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($g in $allGroups) {
        $gid  = if ($g.PSObject.Properties['id']        -and $null -ne $g.id)        { "$($g.id)"        } else { '' }
        $gname= if ($g.PSObject.Properties['groupName'] -and $null -ne $g.groupName) { "$($g.groupName)" } else { '' }
        if (-not $gid) { continue }

        $groupIdToName[$gid] = $gname

        # Determine if LDAP/directory group
        $gtype = if ($g.PSObject.Properties['groupType'] -and $g.groupType) { "$($g.groupType)" } else { '' }
        $dirType = if ($g.PSObject.Properties['directory'] -and $g.directory -and
                       $g.directory.PSObject.Properties['directoryType'] -and $g.directory.directoryType) {
            "$($g.directory.directoryType)"
        } else { '' }

        $isLdap = ($gtype -match '(?i)directory') -or ($dirType -match '(?i)ldap|external|directory')

        if ($isLdap) {
            [void]$ldapGroupIds.Add($gid)
        } else {
            $localGroups.Add([PSCustomObject]@{ GroupID = $gid; GroupName = $gname })
        }
    }

    Write-Host "  Found $($localGroups.Count) local group$(if ($localGroups.Count -ne 1) { 's' }) ($(  $ldapGroupIds.Count) LDAP/Directory excluded)." -ForegroundColor Cyan
    Write-Host ''

    $stack   = [System.Collections.Generic.Stack[hashtable]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $groupIdx = 0

    foreach ($rootGroup in $localGroups) {
        $groupIdx++
        Write-Host "  [$groupIdx/$($localGroups.Count)] $($rootGroup.GroupName)" -ForegroundColor White -NoNewline

        [void]$visited.Clear()
        [void]$stack.Clear()

        $stack.Push(@{
            GroupID   = $rootGroup.GroupID
            GroupName = $rootGroup.GroupName
            Path      = $rootGroup.GroupName
            Depth     = 1
        })

        $memberCount = 0

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            $cid     = $current['GroupID']

            if ($visited.Contains($cid)) { continue }
            [void]$visited.Add($cid)

            $encodedId = [Uri]::EscapeDataString($cid)
            $membersResponse = Invoke-CyberArkAPI `
                -Token     $Token `
                -Method    'GET' `
                -Endpoint  "/API/UserGroups/$encodedId/Members" `
                -IgnoreSSL:$ignoreSSL

            if (-not $membersResponse.IsSuccess) {
                if ($membersResponse.StatusCode -in @(401, 0)) {
                    $result.IsFatal = $true
                    $result.Failures++
                    $result.ItemsProcessed++
                    Write-Host ' - 401 fatal error.' -ForegroundColor Red
                    return $result
                }
                # Non-fatal - group may have restricted access
                Write-CyberArkLog -Level 'WARN' -Message "Export Local Group Members: members for group '$cid' failed - $($membersResponse.ErrorMessage)"
                continue
            }

            $members = if ($membersResponse.Data -and $membersResponse.Data.PSObject.Properties['value']) {
                @($membersResponse.Data.value)
            } else { @() }

            foreach ($m in $members) {
                $memberId   = if ($m.PSObject.Properties['id']       -and $null -ne $m.id)       { "$($m.id)"       } else { '' }
                $memberName = if ($m.PSObject.Properties['username'] -and $m.username)            { "$($m.username)" } else { '' }
                $userType   = if ($m.PSObject.Properties['userType'] -and $m.userType)            { "$($m.userType)" } else { '' }

                # Detect nested group: by userType hint OR by known group ID
                $isLdapMember  = ($memberId -and $ldapGroupIds.Contains($memberId))
                $isLocalGroup  = ($memberId -and $groupIdToName.ContainsKey($memberId) -and -not $isLdapMember) -or
                                 ($userType -match '(?i)group' -and -not $isLdapMember)

                if ($isLdapMember) {
                    # LDAP groups nested inside local groups - list as leaf, do not recurse
                    $nestedName = if ($groupIdToName.ContainsKey($memberId)) { $groupIdToName[$memberId] } else { $memberName }
                    $result.Results.Add([PSCustomObject]@{
                        RootGroupName = $rootGroup.GroupName
                        MemberName    = $nestedName
                        MemberID      = $memberId
                        MemberType    = 'LDAP Group'
                        MemberLevel   = if ($current['Depth'] -eq 1) { 'Parent' } else { 'Child' }
                        Relationship  = $current['Path']
                    })
                    $result.Successes++
                    $result.ItemsProcessed++
                    $memberCount++
                } elseif ($isLocalGroup) {
                    $nestedName = if ($groupIdToName.ContainsKey($memberId)) { $groupIdToName[$memberId] }
                                  elseif ($memberName) { $memberName }
                                  else { $memberId }

                    $result.Results.Add([PSCustomObject]@{
                        RootGroupName = $rootGroup.GroupName
                        MemberName    = $nestedName
                        MemberID      = $memberId
                        MemberType    = 'Group'
                        MemberLevel   = if ($current['Depth'] -eq 1) { 'Parent' } else { 'Child' }
                        Relationship  = $current['Path']
                    })
                    $result.Successes++
                    $result.ItemsProcessed++
                    $memberCount++

                    # Push for recursive expansion (skip if already visited or LDAP)
                    if ($memberId -and -not $visited.Contains($memberId)) {
                        $stack.Push(@{
                            GroupID   = $memberId
                            GroupName = $nestedName
                            Path      = "$($current['Path']) > $nestedName"
                            Depth     = $current['Depth'] + 1
                        })
                    }
                } else {
                    $result.Results.Add([PSCustomObject]@{
                        RootGroupName = $rootGroup.GroupName
                        MemberName    = $memberName
                        MemberID      = $memberId
                        MemberType    = 'User'
                        MemberLevel   = if ($current['Depth'] -eq 1) { 'Parent' } else { 'Child' }
                        Relationship  = $current['Path']
                    })
                    $result.Successes++
                    $result.ItemsProcessed++
                    $memberCount++
                }
            }
        }

        Write-Host " - $memberCount row$(if ($memberCount -ne 1) { 's' })" -ForegroundColor Green
    }

    Write-Host ''
    Write-CyberArkLog -Level 'INFO' -Message "Export Local Group Members complete. Groups: $groupIdx, Rows: $($result.Successes)."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
