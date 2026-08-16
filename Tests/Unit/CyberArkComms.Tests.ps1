#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for CyberArkComms.psm1.
    No CyberArk connection required.

.NOTES
    Invoke-CyberArkAPI error paths (401, 429, etc.) require System.Net.HttpWebResponse
    which cannot be instantiated in pure PowerShell. Those paths are covered by the
    API module tests (Invoke-SafesList.Tests.ps1) via mocking Invoke-CyberArkAPI.
#>

BeforeAll {
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Minimal token stub - no real credentials
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-bearer-token'
        TokenType  = 'Bearer'
        Headers    = @{
            'Authorization' = 'Bearer mock-bearer-token'
            'Content-Type'  = 'application/json'
        }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'ISPSS'
        AuthMethod = 'ClientCredentials'
        BaseURL    = 'https://test.privilegecloud.cyberark.cloud'
    }

    # Suppress log output to console during tests
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'CommsTests' -MinLevel 'ERROR'
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'New-CyberArkQuery' {

    It 'C01 - empty hashtable returns empty string' {
        New-CyberArkQuery -Params @{} | Should -Be ''
    }

    It 'C02 - single param returns query string with leading ?' {
        $result = New-CyberArkQuery -Params @{ search = 'vault' }
        $result | Should -Be '?search=vault'
    }

    It 'C03 - multiple params all appear in the result' {
        $result = New-CyberArkQuery -Params @{ search = 'vault'; limit = '25' }
        $result | Should -Match '^\?'
        $result | Should -Match 'search=vault'
        $result | Should -Match 'limit=25'
    }

    It 'C04 - null value is omitted' {
        $result = New-CyberArkQuery -Params @{ search = 'vault'; filter = $null }
        $result | Should -Not -Match 'filter'
    }

    It 'C05 - empty string value is omitted' {
        $result = New-CyberArkQuery -Params @{ search = 'vault'; sort = '' }
        $result | Should -Not -Match 'sort'
    }

    It 'C06 - value with spaces is URL-encoded' {
        $result = New-CyberArkQuery -Params @{ filter = 'safeName eq My Safe' }
        $result | Should -Not -Match ' '
        $result | Should -Match 'filter='
    }

    It 'C07 - special characters in value are encoded' {
        $result = New-CyberArkQuery -Params @{ filter = 'name eq a&b' }
        # Ampersand should be encoded
        $result | Should -Match '%26'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Join-CyberArkUrl' {

    It 'C08 - base and one segment joined with single slash' {
        Join-CyberArkUrl -Base 'https://host.example.com' -Segments @('/API/Safes') |
            Should -Be 'https://host.example.com/API/Safes'
    }

    It 'C09 - trailing slash on base is trimmed' {
        Join-CyberArkUrl -Base 'https://host.example.com/' -Segments @('/API/Safes') |
            Should -Be 'https://host.example.com/API/Safes'
    }

    It 'C10 - leading slash on segment is trimmed (no double slash)' {
        Join-CyberArkUrl -Base 'https://host.example.com' -Segments @('/API/Safes') |
            Should -Not -Match '//API'
    }

    It 'C11 - multiple segments all joined' {
        Join-CyberArkUrl -Base 'https://host.example.com' -Segments @('API', 'Safes', 'MySafe') |
            Should -Be 'https://host.example.com/API/Safes/MySafe'
    }

    It 'C12 - segment with trailing slash is trimmed' {
        Join-CyberArkUrl -Base 'https://host.example.com' -Segments @('API/Safes/') |
            Should -Be 'https://host.example.com/API/Safes'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'New-CyberArkSearchFilter' {

    It 'C13 - single criterion produces correct expression' {
        New-CyberArkSearchFilter -Criteria @{ safeName = 'MySafe' } |
            Should -Be 'safeName eq MySafe'
    }

    It 'C14 - two criteria joined with AND by default' {
        $result = New-CyberArkSearchFilter -Criteria @{ safeName = 'MySafe'; location = 'Root' }
        $result | Should -Match 'AND'
        $result | Should -Match 'safeName eq MySafe'
        $result | Should -Match 'location eq Root'
    }

    It 'C15 - value containing spaces is double-quoted' {
        New-CyberArkSearchFilter -Criteria @{ description = 'My Safe Description' } |
            Should -Match '"My Safe Description"'
    }

    It 'C16 - custom operator OR used when specified' {
        $result = New-CyberArkSearchFilter -Criteria @{ a = '1'; b = '2' } -Operator 'OR'
        $result | Should -Match 'OR'
        $result | Should -Not -Match 'AND'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-CyberArkAPI - success paths (mocked Invoke-WebRequest)' {

    BeforeAll {
        # Build a minimal success response object that Invoke-WebRequest returns
        # UseBasicParsing returns an object with StatusCode and Content
        function script:New-MockWebResponse {
            param([int]$StatusCode = 200, [string]$Body = '')
            return [PSCustomObject]@{ StatusCode = $StatusCode; Content = $Body }
        }
    }

    It 'C17 - GET 200 with JSON body returns IsSuccess=$true and parsed Data' {
        $json = '{"value":[{"safeName":"TestSafe"}],"count":1}'
        Mock Invoke-WebRequest { script:New-MockWebResponse -StatusCode 200 -Body $json } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0
        $r.IsSuccess     | Should -BeTrue
        $r.StatusCode    | Should -Be 200
        $r.DataType      | Should -Be 'JSON'
        $r.Data          | Should -Not -BeNullOrEmpty
        $r.Data.value[0].safeName | Should -Be 'TestSafe'
    }

    It 'C18 - POST 201 returns IsSuccess=$true and StatusCode=201' {
        $json = '{"id":"abc123","safeName":"NewSafe"}'
        Mock Invoke-WebRequest { script:New-MockWebResponse -StatusCode 201 -Body $json } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Safes' `
            -Body @{ safeName = 'NewSafe' }
        $r.IsSuccess  | Should -BeTrue
        $r.StatusCode | Should -Be 201
    }

    It 'C19 - 204 No Content returns IsSuccess=$true and DataType=Empty' {
        Mock Invoke-WebRequest { script:New-MockWebResponse -StatusCode 204 -Body '' } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'DELETE' -Endpoint '/API/Safes/OldSafe'
        $r.IsSuccess | Should -BeTrue
        $r.DataType  | Should -Be 'Empty'
        $r.Data      | Should -BeNullOrEmpty
    }

    It 'C20 - WhatIf suppresses POST and returns synthetic success' {
        Mock Invoke-WebRequest { throw 'Should not be called' } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' `
            -Endpoint '/API/Safes' -Body @{ safeName = 'X' } -WhatIf
        $r.IsSuccess  | Should -BeTrue
        $r.StatusCode | Should -Be 200
        Should -Invoke Invoke-WebRequest -Times 0 -ModuleName 'CyberArkComms'
    }

    It 'C21 - WhatIf suppresses PUT' {
        Mock Invoke-WebRequest { throw 'Should not be called' } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'PUT' `
            -Endpoint '/API/Safes/X' -Body @{ description = 'Y' } -WhatIf
        $r.IsSuccess | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 0 -ModuleName 'CyberArkComms'
    }

    It 'C22 - WhatIf suppresses DELETE' {
        Mock Invoke-WebRequest { throw 'Should not be called' } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'DELETE' `
            -Endpoint '/API/Safes/X' -WhatIf
        $r.IsSuccess | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 0 -ModuleName 'CyberArkComms'
    }

    It 'C23 - WhatIf does NOT suppress GET' {
        $json = '{"value":[],"count":0}'
        Mock Invoke-WebRequest { script:New-MockWebResponse -StatusCode 200 -Body $json } `
            -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -WhatIf -PageSize 0 | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -ModuleName 'CyberArkComms'
    }

    It 'C24 - QueryParams are appended to the request URI' {
        $json = '{"value":[],"count":0}'
        $capturedUri = $null
        Mock Invoke-WebRequest {
            param($Uri) ; Set-Variable -Name capturedUri -Value $Uri -Scope Script
            script:New-MockWebResponse -StatusCode 200 -Body $json
        } -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -QueryParams @{ search = 'myvault' } -PageSize 0 | Out-Null

        $script:capturedUri | Should -Match 'search=myvault'
    }

    It 'C25 - Body is sent with JSON Content-Type' {
        $json = '{"id":"123"}'
        $capturedContentType = $null
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $Body, $ContentType, $UseBasicParsing, $ErrorAction)
            Set-Variable -Name capturedContentType -Value $ContentType -Scope Script
            script:New-MockWebResponse -StatusCode 201 -Body $json
        } -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Safes' `
            -Body @{ safeName = 'X' } | Out-Null

        $script:capturedContentType | Should -Be 'application/json'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-CyberArkAPI - pagination (mocked Invoke-WebRequest)' {

    It 'C26 - two full pages combined into single value array' {
        $page1 = '{"value":[{"safeName":"Safe1"},{"safeName":"Safe2"}],"count":4}'
        $page2 = '{"value":[{"safeName":"Safe3"},{"safeName":"Safe4"}],"count":4}'
        $page3 = '{"value":[],"count":4}'  # empty page terminates pagination
        $callCount = 0
        Mock Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                [PSCustomObject]@{ StatusCode = 200; Content = $page1 }
            } elseif ($script:callCount -eq 2) {
                [PSCustomObject]@{ StatusCode = 200; Content = $page2 }
            } else {
                [PSCustomObject]@{ StatusCode = 200; Content = $page3 }
            }
        } -ModuleName 'CyberArkComms'

        $script:callCount = 0
        # PageSize=2 so two items per page triggers a second fetch; empty 3rd page terminates
        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -PageSize 2
        $r.Data.value.Count | Should -Be 4
    }

    It 'C27 - final page smaller than PageSize stops pagination' {
        $page1 = '{"value":[{"safeName":"S1"},{"safeName":"S2"}],"count":3}'
        $page2 = '{"value":[{"safeName":"S3"}],"count":3}'
        $callCount = 0
        Mock Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                [PSCustomObject]@{ StatusCode = 200; Content = $page1 }
            } else {
                [PSCustomObject]@{ StatusCode = 200; Content = $page2 }
            }
        } -ModuleName 'CyberArkComms'

        $script:callCount = 0
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -PageSize 2 | Out-Null
        $script:callCount | Should -Be 2   # exactly 2 requests, not 3
    }

    It 'C28 - PageSize=0 disables pagination (single request)' {
        $json = '{"value":[{"safeName":"S1"}],"count":1}'
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200; Content = $json } } `
            -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -PageSize 0 | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -ModuleName 'CyberArkComms'
    }
}
