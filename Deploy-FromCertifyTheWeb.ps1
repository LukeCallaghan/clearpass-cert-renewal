#Requires -Version 5.1
param($result, [string]$Services = '')

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'This script requires Windows PowerShell 5.1. PowerShell 7 is not supported.'
}


$ErrorActionPreference = 'Stop'

$BasePath = $PSScriptRoot
$SecretsPath = Join-Path $BasePath 'secrets.json'
$ConfigPath = Join-Path $BasePath 'config.json'
$DeployScript = Join-Path $BasePath 'Deploy-ClearPassCertificate.ps1'

try {
    # Only deploy after successful issuance
    if ($null -ne $result -and -not $result.IsSuccess) {
        throw 'Certify The Web certificate request failed.'
    }

    # Explicit selection prevents one renewal from deploying unrelated exports.
    $selectedServices = @($Services -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($selectedServices.Count -eq 0) { throw 'Specify Services for this renewal, e.g. HTTPS(RSA) or HTTPS(RSA),RADIUS.' }

    # Load credentials
    $Secrets = Get-Content -LiteralPath $SecretsPath -Raw |
    ConvertFrom-Json

    # Set environment variables for deployment script
    $env:CPPM_CLIENT_ID = $Secrets.ClientId
    $env:CPPM_CLIENT_SECRET = $Secrets.ClientSecret
    $env:CPPM_HTTPS_PFX_PASSWORD = $Secrets.HttpsPfxPassword
    $env:CPPM_RADIUS_PFX_PASSWORD = $Secrets.RadiusPfxPassword

    Write-Host 'Starting ClearPass certificate deployment...'

    # Call existing deployment script
    & $DeployScript -ConfigPath $ConfigPath -Services $selectedServices

    if (-not $?) {
        throw 'ClearPass deployment script failed.'
    }

    Write-Host 'ClearPass deployment script completed.'
}
catch {
    Write-Error "ClearPass deployment failed: $($_.Exception.Message)"
    throw
}
finally {
    # Remove environment variables from this process
    Remove-Item Env:\CPPM_CLIENT_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\CPPM_CLIENT_SECRET -ErrorAction SilentlyContinue
    Remove-Item Env:\CPPM_HTTPS_PFX_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\CPPM_RADIUS_PFX_PASSWORD -ErrorAction SilentlyContinue
}
