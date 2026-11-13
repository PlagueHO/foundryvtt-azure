BeforeAll {
    $privateScript = Join-Path $PSScriptRoot '..\scripts\Test-PrivateWebAppAccess.ps1'
    $parameters = @{
        SubscriptionId = '00000000-0000-0000-0000-000000000001'
        TenantId = '00000000-0000-0000-0000-000000000002'
        WebAppName = 'fvtt-asp-on-123-1'
        ResourceGroupName = 'rg-fvtt-asp-on-123-1'
        EvidencePath = Join-Path $TestDrive 'access.txt'
        WhatIf = $true
    }
}

Describe 'Private access test scope' {
    It 'refuses production names before Azure access' {
        $invalid = $parameters.Clone()
        $invalid.WebAppName = 'production'
        { & $privateScript @invalid } | Should -Throw '*does not match*'
    }

    It 'refuses a different resource group before Azure access' {
        $invalid = $parameters.Clone()
        $invalid.ResourceGroupName = 'rg-production'
        { & $privateScript @invalid } | Should -Throw '*does not match the isolated private test*'
    }
}
