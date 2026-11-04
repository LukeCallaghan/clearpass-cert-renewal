#Requires -Version 5.1
param([string]$ConfigPath = "$PSScriptRoot\config.json", [switch]$DryRun, [switch]$Force, [string[]]$Services = @())
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'This script requires Windows PowerShell 5.1. PowerShell 7 is not supported.'
}
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$base = ([string]$cfg.ClearPass.ApiBaseUrl).TrimEnd('/')
$dry = [bool]$cfg.Deployment.DryRun -or $DryRun.IsPresent
# Supports new per-service Certificates object, or the original single-service configuration.
$certConfigs = @()
if ($cfg.PSObject.Properties.Name -contains 'Certificates' -and $null -ne $cfg.Certificates) {
    foreach ($prop in $cfg.Certificates.PSObject.Properties) {
        $svc = [string]$prop.Name
        if ($svc -cnotin @('HTTPS(RSA)', 'HTTPS(ECC)', 'RADIUS', 'RadSec')) { throw "Unsupported service: $svc" }
        $entry = $prop.Value
        if (-not $entry.PfxPath -or -not $entry.PfxPasswordEnv) { throw "Certificates.$svc requires PfxPath and PfxPasswordEnv" }
        $certConfigs += [pscustomobject]@{ Service = $svc; PfxPath = [string]$entry.PfxPath; PasswordEnv = [string]$entry.PfxPasswordEnv }
    }
}
else {
    $svc = [string]$cfg.ClearPass.Service
    if ($svc -cnotin @('HTTPS(RSA)', 'HTTPS(ECC)', 'RADIUS', 'RadSec')) { throw "Unsupported service: $svc" }
    $certConfigs += [pscustomobject]@{ Service = $svc; PfxPath = [string]$cfg.Certificate.PfxPath; PasswordEnv = [string]$cfg.Certificate.PfxPasswordEnv }
}
if ($Services.Count -gt 0) {
    foreach ($service in $Services) {
        if ($service -cnotin @($certConfigs.Service)) { throw "Service is not configured: $service" }
    }
    $certConfigs = @($certConfigs | Where-Object { $_.Service -cin $Services })
}
if ($certConfigs.Count -eq 0) { throw 'No certificate services configured.' }
$listen = [string]$cfg.Delivery.ListenAddress
$advertise = [string]$cfg.Delivery.AdvertiseAddress
$port = [int]$cfg.Delivery.Port
$allowed = @($cfg.Delivery.AllowedSourceIPs | Where-Object { $_ })
$timeout = [int]$cfg.Delivery.RequestTimeoutSeconds
$sessionDir = Join-Path ([IO.Path]::GetTempPath()) ('cppm-deploy-' + [guid]::NewGuid().ToString('N'))
$process = $null; $firewallName = $null; $readyFile = $null; $stopFile = $null
$securityCallbackChanged = $false; $oldCallback = $null
# VerifySSL defaults to true. Accept the previous SkipTlsValidation setting for backward compatibility.
$verifySsl = $true
$clearPassSettings = @($cfg.ClearPass.PSObject.Properties.Name)
if ($clearPassSettings -contains 'VerifySSL') {
    if ($cfg.ClearPass.VerifySSL -isnot [bool]) { throw 'ClearPass.VerifySSL must be a JSON boolean (true or false).' }
    $verifySsl = [bool]$cfg.ClearPass.VerifySSL
}
elseif ($clearPassSettings -contains 'SkipTlsValidation') {
    if ($cfg.ClearPass.SkipTlsValidation -isnot [bool]) { throw 'ClearPass.SkipTlsValidation must be a JSON boolean (true or false).' }
    $verifySsl = -not [bool]$cfg.ClearPass.SkipTlsValidation
}
function Get-EnvRequired([string]$variable) {
    $value = [Environment]::GetEnvironmentVariable($variable)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Required environment variable missing: $variable" }
    return $value
}
function Invoke-Cppm([string]$Method, [string]$Path, $Body = $null, [string]$Token = '') {
    $headers = @{ Accept = 'application/json' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    $args = @{ Uri = "$base$Path"; Method = $Method; Headers = $headers; TimeoutSec = $timeout; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $args.ContentType = 'application/json'; $args.Body = ($Body | ConvertTo-Json -Depth 5 -Compress) }
    return Invoke-RestMethod @args
}
function Convert-CppmExpiryToUtc([string]$ExpiryText) {
    # Format from ClearPass: "Jan 31, 2027 16:25:38 AEST".
    # Parse the date without relying on the Windows locale/timezone.
    if ([string]::IsNullOrWhiteSpace($ExpiryText)) { return $null }
    $m = [regex]::Match($ExpiryText.Trim(), '^(?<date>[A-Za-z]+\s+\d{1,2},\s+\d{4}\s+\d{2}:\d{2}:\d{2})\s+(?<zone>[A-Za-z]{2,5}|[+-]\d{2}:?\d{2})$')
    if (-not $m.Success) { return $null }
    $offsets = @{
        UTC = '+00:00'; GMT = '+00:00'; AEST = '+10:00'; AEDT = '+11:00'
        ACST = '+09:30'; ACDT = '+10:30'; AWST = '+08:00'
        NZST = '+12:00'; NZDT = '+13:00'
        PST = '-08:00'; PDT = '-07:00'; MST = '-07:00'; MDT = '-06:00'
        CST = '-06:00'; CDT = '-05:00'; EST = '-05:00'; EDT = '-04:00'
    }
    $zone = $m.Groups['zone'].Value.ToUpperInvariant()
    if ($offsets.ContainsKey($zone)) { $offset = $offsets[$zone] }
    elseif ($zone -match '^[+-]\d{4}$') { $offset = $zone.Substring(0, 3) + ':' + $zone.Substring(3, 2) }
    elseif ($zone -match '^[+-]\d{2}:\d{2}$') { $offset = $zone }
    else { return $null }
    $dateString = $m.Groups['date'].Value
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $formats = [string[]]@('MMM d, yyyy HH:mm:ss', 'MMM dd, yyyy HH:mm:ss', 'MMMM d, yyyy HH:mm:ss', 'MMMM dd, yyyy HH:mm:ss')
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($dateString, $formats, $culture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $null }
    # SpecifyKind avoids a workstation's local timezone affecting the conversion.
    $dt = [datetime]::SpecifyKind($dt, [DateTimeKind]::Unspecified)
    $sign = if ($offset.StartsWith('-')) { -1 } else { 1 }
    $hours = [int]$offset.Substring(1, 2)
    $minutes = [int]$offset.Substring(4, 2)
    if ($hours -gt 14 -or $minutes -gt 59) { return $null }
    $span = [TimeSpan]::FromMinutes($sign * ($hours * 60 + $minutes))
    try { return ([DateTimeOffset]::new($dt, $span)).UtcDateTime }
    catch { return $null }
}

function Assert-CppmCertificate($Actual, $Expected) {
    # Check thumbprint if the API provides it, otherwise compare subject and expiry.
    $reportedThumbprint = $null
    foreach ($key in @('fingerprint', 'thumbprint', 'sha1_fingerprint')) {
        if ($Actual.PSObject.Properties.Name -contains $key) { $reportedThumbprint = [string]$Actual.$key; break }
    }
    if ($reportedThumbprint) {
        $normalized = $reportedThumbprint -replace '[^0-9a-fA-F]', ''
        if ($normalized.ToUpperInvariant() -cne $Expected.Thumbprint.ToUpperInvariant()) { throw 'Read-back fingerprint mismatch.' }
    }
    else {
        if ([string]$Actual.subject -ne [string]$Expected.Subject) { throw "Read-back subject mismatch ($($Actual.subject))" }
        $ActualExpiry = Convert-CppmExpiryToUtc ([string]$Actual.expiry_date)
        if ($null -eq $ActualExpiry) { throw 'Read-back expiry could not be parsed; certificate verification failed.' }
        if ([Math]::Abs(($ActualExpiry - $Expected.NotAfter.ToUniversalTime()).TotalSeconds) -gt 1) { throw 'Read-back expiry mismatch.' }
        Write-Warning 'API did not provide a recognised fingerprint field; subject and expiry match, but confirm the active certificate independently.'
    }
}

function Read-NodeCertificate([string]$uuid, [string]$svc, [string]$token) {
    $svcEscaped = [uri]::EscapeDataString($svc)
    return Invoke-Cppm GET "/api/server-cert/name/$uuid/$svcEscaped" $null $token
}
try {
    if ($base -notmatch '^https://') { throw 'ClearPass API URL must use HTTPS.' }
    $certificates = @()
    foreach ($entry in $certConfigs) {
        $pfx = [Environment]::ExpandEnvironmentVariables($entry.PfxPath)
        if (-not [IO.Path]::IsPathRooted($pfx)) { $pfx = Join-Path $PSScriptRoot $pfx }
        $pfx = [IO.Path]::GetFullPath($pfx)
        if (-not (Test-Path -LiteralPath $pfx -PathType Leaf)) { throw "PFX not found for $($entry.Service): $pfx" }
        $certificates += [pscustomobject]@{ Service = $entry.Service; Pfx = $pfx; PasswordEnv = $entry.PasswordEnv }
    }
    if ($allowed.Count -eq 0) { throw 'AllowedSourceIPs must contain one or more ClearPass source IP addresses.' }
    foreach ($ip in $allowed + @($listen, $advertise)) {
        if (-not [System.Net.IPAddress]::TryParse($ip, [ref]([System.Net.IPAddress]$null))) { throw "Invalid IP: $ip" }
    }
    if ($port -lt 1 -or $port -gt 65535) { throw 'Invalid Delivery.Port' }
    if (-not $dry -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Live deployment requires elevated PowerShell (Windows Firewall).' }
    if (-not $verifySsl) {
        Write-Warning 'ClearPass.VerifySSL=false: TLS certificate validation is DISABLED for this PowerShell process. API authentication is vulnerable to interception. Use only with explicit risk acceptance.'
        $oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $securityCallbackChanged = $true
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $clientId = Get-EnvRequired ([string]$cfg.ClearPass.ApiClientIdEnv)
    $clientSecret = Get-EnvRequired ([string]$cfg.ClearPass.ApiClientSecretEnv)
    foreach ($entry in $certificates) {
        $entry | Add-Member -NotePropertyName Password -NotePropertyValue (Get-EnvRequired $entry.PasswordEnv)
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($entry.Pfx, $entry.Password, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        try {
            if (-not $cert.HasPrivateKey) { throw "PFX for $($entry.Service) has no private key." }
            if ($cert.NotAfter -le (Get-Date)) { throw "PFX for $($entry.Service) has expired." }
            $entry | Add-Member -NotePropertyName Subject -NotePropertyValue $cert.Subject
            $entry | Add-Member -NotePropertyName Thumbprint -NotePropertyValue $cert.Thumbprint
            $entry | Add-Member -NotePropertyName NotAfter -NotePropertyValue $cert.NotAfter
            Write-Host "$($entry.Service): Subject=$($cert.Subject); Expires=$($cert.NotAfter.ToString('u')); Thumbprint=$($cert.Thumbprint)"
        }
        finally { $cert.Dispose() }
    }
    $oauth = Invoke-Cppm POST '/api/oauth' @{grant_type = 'client_credentials'; client_id = $clientId; client_secret = $clientSecret }
    if (-not $oauth.access_token) { throw 'OAuth response did not include access_token' }
    $token = [string]$oauth.access_token
    $nodes = @()
    if ([bool]$cfg.ClearPass.DiscoverCluster) {
        $result = Invoke-Cppm GET '/api/cluster/server' $null $token
        if ($null -ne $result._embedded -and $null -ne $result._embedded.items) {
            $nodes = @($result._embedded.items | Where-Object { $_.server_uuid })
        }
    }
    if ($nodes.Count -eq 0) {
        if ($cfg.ClearPass.StandaloneUuid) {
            $nodes = @([pscustomobject]@{name = 'Standalone'; server_uuid = [string]$cfg.ClearPass.StandaloneUuid })
            Write-Host 'No cluster nodes returned; using configured standalone UUID.'
        }
        else { throw 'No cluster nodes returned. Supply ClearPass.StandaloneUuid for standalone fallback (obtain from /api/cluster/server or API Explorer).' }
    }
    $allowUuids = @($cfg.ClearPass.AllowedNodeUuids | Where-Object { $_ })
    if ($allowUuids.Count -gt 0) { $nodes = @($nodes | Where-Object { $_.server_uuid -in $allowUuids }) }
    if ($nodes.Count -eq 0) { throw 'No nodes remain after AllowedNodeUuids filtering.' }
    $uniqueNodes = @($nodes | Group-Object server_uuid | ForEach-Object { $_.Group[0] })
    Write-Host "Targets ($($uniqueNodes.Count)):"
    $uniqueNodes | ForEach-Object { Write-Host "  $($_.name)  $($_.server_uuid)" }
    $actions = @()
    foreach ($entry in $certificates) {
        foreach ($node in $uniqueNodes) {
            $current = Read-NodeCertificate ([string]$node.server_uuid) $entry.Service $token
            $expiryText = [string]$current.expiry_date
            Write-Host "Current $($node.name) / $($entry.Service): $($current.subject) expiry $expiryText"
            $selfSigned = ($current.subject -and $current.issued_by -and ([string]$current.subject -eq [string]$current.issued_by))
            $currentExpiry = Convert-CppmExpiryToUtc $expiryText
            $parsed = ($null -ne $currentExpiry)
            if ($parsed) { Write-Host "  Parsed expiry (UTC): $($currentExpiry.ToString('u'))" }
            $shouldReplace = $Force.IsPresent -or [bool]$cfg.Deployment.ForceReplace -or $selfSigned -or ($parsed -and $currentExpiry -lt $entry.NotAfter.ToUniversalTime())
            if (-not $parsed -and -not $selfSigned -and -not $Force.IsPresent -and -not [bool]$cfg.Deployment.ForceReplace) {
                Write-Warning "Could not parse expiry for $($node.name) / $($entry.Service). Skipping; use -Force only after reviewing."
            }
            $actions += [pscustomobject]@{Node = $node; Certificate = $entry; Replace = [bool]$shouldReplace }
            Write-Host "  Planned action: $(if($shouldReplace){'IMPORT'}else{'SKIP'})"
        }
    }
    if ($dry) { Write-Host 'DRY RUN: no HTTP listener, firewall changes, or certificate imports performed.'; return }
    $pending = @($actions | Where-Object Replace)
    if ($pending.Count -eq 0) { Write-Host 'Nothing to update.'; return }
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    $firewallName = "CPPM temporary PFX $([guid]::NewGuid().ToString('N'))"
    New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow -Protocol TCP -LocalAddress $listen -LocalPort $port -RemoteAddress $allowed -Profile Any | Out-Null
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $serverScript = Join-Path $PSScriptRoot 'Serve-Pfx.ps1'
    $failures = 0
    # One short-lived listener per service; only its designated PFX can be served.
    foreach ($entry in $certificates) {
        $serviceActions = @($pending | Where-Object { $_.Certificate.Service -ceq $entry.Service })
        if ($serviceActions.Count -eq 0) { continue }
        $readyFile = Join-Path $sessionDir 'ready'
        $stopFile = Join-Path $sessionDir 'stop'
        $logFile = Join-Path $sessionDir 'listener.log'
        Remove-Item -LiteralPath $readyFile, $stopFile -Force -ErrorAction SilentlyContinue
        $urlToken = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
        $serverArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $serverScript + '"'), '-BindAddress', $listen, '-Port', "$port", '-FilePath', ('"' + $entry.Pfx + '"'), '-UrlToken', $urlToken, '-ReadyFile', ('"' + $readyFile + '"'), '-StopFile', ('"' + $stopFile + '"'), '-LogFile', ('"' + $logFile + '"'))
        try {
            $process = Start-Process -FilePath $psExe -ArgumentList $serverArgs -PassThru -WindowStyle Hidden
            $until = (Get-Date).AddSeconds([int]$cfg.Delivery.StartupTimeoutSeconds)
            while (-not (Test-Path $readyFile)) {
                if ($process.HasExited) { throw "PFX server exited prematurely. Review $logFile" }
                if ((Get-Date) -ge $until) { throw "PFX server did not start. Review $logFile" }
                Start-Sleep -Milliseconds 150
            }
            $pfxUrl = "http://${advertise}:$port/$urlToken/certificate.pfx"
            Write-Host "Temporary HTTP listener ready for $($entry.Service) on ${listen}:$port"
            foreach ($action in $serviceActions) {
                $node = $action.Node
                try {
                    Write-Host "Importing $($entry.Service) on $($node.name)..."
                    $s = [uri]::EscapeDataString($entry.Service)
                    $null = Invoke-Cppm PUT "/api/server-cert/name/$($node.server_uuid)/$s" @{pkcs12_file_url = $pfxUrl; pkcs12_passphrase = $entry.Password } $token
                    if ([bool]$cfg.Deployment.VerifyAfterImport) {
                        $after = Read-NodeCertificate ([string]$node.server_uuid) $entry.Service $token
                        Assert-CppmCertificate $after $entry
                        Write-Host "  Import accepted; read-back checked for $($entry.Service)."
                    }
                    else { Write-Host '  Import API accepted the request (not independently verified).' }
                }
                catch {
                    $failures++
                    Write-Warning "Node $($node.name) / $($entry.Service) failed: $($_.Exception.Message)"
                    if ([bool]$cfg.Deployment.StopOnError) { break }
                }
            }
        }
        finally {
            New-Item -ItemType File -Path $stopFile -Force | Out-Null
            if ($process) {
                if (-not $process.WaitForExit(3000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
                $process.Dispose(); $process = $null
            }
            Remove-Item -LiteralPath $readyFile, $stopFile -Force -ErrorAction SilentlyContinue
        }
        if ($failures -and [bool]$cfg.Deployment.StopOnError) { break }
    }
    if ($failures) { throw "$failures service/node import(s) failed. Check status and do not assume rollout completed." }
    Write-Host 'Completed. Confirm installed certificate and HTTPS/EAP health independently.'

}
finally {
    if ($stopFile -and (Test-Path (Split-Path $stopFile))) { New-Item -ItemType File -Path $stopFile -Force | Out-Null }
    if ($process) {
        if (-not $process.WaitForExit(3000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        $process.Dispose()
    }
    if ($firewallName) { Remove-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue }
    if ($securityCallbackChanged) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
    if ($sessionDir -and (Test-Path $sessionDir)) { Remove-Item -LiteralPath $sessionDir -Recurse -Force -ErrorAction SilentlyContinue }
}
