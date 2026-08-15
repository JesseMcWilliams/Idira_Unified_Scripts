@{
    # CyberArk self-hosted PVWA connection
    PVWABaseURL    = 'https://pvwa.company.com/PasswordVault'
    AuthMethod     = 'CyberArk'
    Username       = 'ca_admin'
    SystemType     = 'SelfHosted'
    IgnoreSSL      = $false

    # Safe that MUST NEVER be modified or deleted by tests
    ExcludedSafe   = 'Z_Template_Safe_Permissions'

    # Prefix for safes created during integration tests (must be unique enough to avoid collision)
    TestSafePrefix = 'IDIRA_IntTest'

    # Name of the write-test safe (created fresh, then deleted at end)
    TestSafeName   = 'IDIRA_IntTest_Safes'

    # How long to wait (seconds) between write operations to avoid rate limiting
    WriteDelaySec  = 1
}
