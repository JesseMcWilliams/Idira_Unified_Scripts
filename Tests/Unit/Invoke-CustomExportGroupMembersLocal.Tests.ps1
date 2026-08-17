#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-CustomExportGroupMembersLocal.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Custom\Invoke-CustomExportGroupMembersLocal.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'CustomExportLocalTests' -MinLevel 'ERROR'
}

Describe 'Invoke-CustomExportGroupMembersLocal' {

    BeforeEach {
        $script:ActiveProfile = $null
    }

    Context 'Group list API failure' {
        It 'returns failure when group list API fails' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 500; ErrorMessage = 'Server Error'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-CustomExportGroupMembersLocal -Token $token -InputData @{}
            $result.Failures  | Should -BeGreaterThan 0
            $result.Successes | Should -Be 0
        }

        It 'sets IsFatal on 401 from group list' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401; ErrorMessage = 'Unauthorized'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-CustomExportGroupMembersLocal -Token $token -InputData @{}
            $result.IsFatal | Should -Be $true
        }
    }

    Context 'No groups returned' {
        It 'returns empty result when group list is empty' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $emptyData = [PSCustomObject]@{ value = @() }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $emptyData }
            }
            $result = Invoke-CustomExportGroupMembersLocal -Token $token -InputData @{}
            $result.Successes     | Should -Be 0
            $result.Results.Count | Should -Be 0
        }
    }

    Context 'Only LDAP groups returned' {
        It 'returns empty result when all groups are LDAP/Directory type' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $groupsData = [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{
                        id = 1; groupName = 'LDAPGroup1'; groupType = 'Directory'; description = ''
                        location = ''; directory = [PSCustomObject]@{ directoryType = 'LDAP' }
                    }
                )
            }
            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/UserGroups' } {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $groupsData }
            }
            $result = Invoke-CustomExportGroupMembersLocal -Token $token -InputData @{}
            $result.Successes     | Should -Be 0
            $result.Results.Count | Should -Be 0
        }
    }

    Context 'Local group with direct user members' {
        It 'returns user member rows with MemberLevel Parent' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

            $groupsData = [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ id = 10; groupName = 'LocalGroup1'; groupType = 'EPVGroup'; description = ''; location = '' }
                )
            }
            $membersData = [PSCustomObject]@{
                id      = 10
                members = @(
                    [PSCustomObject]@{ id = 100; username = 'user1'; userType = 'EPVUser'; componentUser = $false }
                )
            }

            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/UserGroups' } {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $groupsData }
            }
            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -like '/API/UserGroups/*' } {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $membersData }
            }

            $result = Invoke-CustomExportGroupMembersLocal -Token $token -InputData @{}
            $result.Successes          | Should -BeGreaterThan 0
            $result.Results.Count      | Should -BeGreaterThan 0
            $result.Results[0].MemberType  | Should -Be 'User'
            $result.Results[0].MemberLevel | Should -Be 'Parent'
            $result.Results[0].RootGroupName | Should -Be 'LocalGroup1'
            $result.Results[0].Relationship  | Should -Be 'LocalGroup1'
        }
    }

    Context 'Local group with nested group member' {
        It 'recursion adds nested group row with Child level' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

            $groupsData = [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ id = 10; groupName = 'ParentGroup'; groupType = 'EPVGroup'; description = ''; location = '' }
                    [PSCustomObject]@{ id = 20; groupName = 'ChildGroup';  groupType = 'EPVGroup'; description = ''; location = '' }
                )
            }

            # ParentGroup members: ChildGroup (nested)
            $parentMembersData = [PSCustomObject]@{
                id      = 10
                members = @(
                    [PSCustomObject]@{ id = 20; username = 'ChildGroup'; userType = 'EPVGroup'; componentUser = $false }
                )
            }
            # ChildGroup members: a user
            $childMembersData = [PSCustomObject]@{
                id      = 20
                members = @(
                    [PSCustomObject]@{ id = 101; username = 'nested_user'; userType = 'EPVUser'; componentUser = $false }
                )
            }

            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/UserGroups' } {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $groupsData }
            }
            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -like '*/UserGroups/10' } {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $parentMembersData }
            }
            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -like '*/UserGroups/20' } {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $childMembersData }
            }

            $result = Invoke-CustomExportGroupMembersLocal -Token $token -InputData @{}
            $result.Successes      | Should -BeGreaterThan 0

            $groupRow = $result.Results | Where-Object { $_.MemberType -eq 'Group' }
            $groupRow | Should -Not -BeNullOrEmpty
            $groupRow.MemberLevel | Should -Be 'Parent'  # Direct member of root

            # nested_user appears both as a direct member of ChildGroup (Parent) and via ParentGroup recursion (Child)
            $childRow = $result.Results | Where-Object { $_.MemberName -eq 'nested_user' -and $_.MemberLevel -eq 'Child' }
            $childRow | Should -Not -BeNullOrEmpty
        }
    }

}
