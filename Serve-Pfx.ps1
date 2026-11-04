#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$BindAddress,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string]$UrlToken,
    [Parameter(Mandatory)][string]$ReadyFile,
    [Parameter(Mandatory)][string]$StopFile,
    [Parameter(Mandatory)][string]$LogFile
)
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'This script requires Windows PowerShell 5.1. PowerShell 7 is not supported.'
}
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$listener = $null
try {
    $ip = [System.Net.IPAddress]::Parse($BindAddress)
    $listener = [System.Net.Sockets.TcpListener]::new($ip, $Port)
    $listener.Start()
    [IO.File]::WriteAllText($ReadyFile, 'ready')
    while (-not [IO.File]::Exists($StopFile)) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $client = $null
        try {
            $client = $listener.AcceptTcpClient()
            $client.ReceiveTimeout = 5000; $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            if (-not $requestLine) { continue }
            # Drain HTTP headers, with a bounded count and TCP read timeout.
            for ($i=0; $i -lt 100; $i++) {
                $h = $reader.ReadLine()
                if ($null -eq $h -or $h -eq '') { break }
            }
            $expected = "/$UrlToken/certificate.pfx"
            $parts = $requestLine -split ' '
            $valid = $parts.Length -eq 3 -and $parts[0] -eq 'GET' -and $parts[1] -ceq $expected -and $parts[2] -match '^HTTP/1\.[01]$'
            if ($valid) {
                $bytes = [IO.File]::ReadAllBytes($FilePath)
                $header = "HTTP/1.1 200 OK`r`nContent-Type: application/x-pkcs12`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
                $head = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($head,0,$head.Length)
                $stream.Write($bytes,0,$bytes.Length)
                $stream.Flush()
                [IO.File]::AppendAllText($LogFile,"$(Get-Date -Format o) served to $($client.Client.RemoteEndPoint)`r`n")
            } else {
                $b = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $stream.Write($b,0,$b.Length)
            }
        } catch {
            [IO.File]::AppendAllText($LogFile,"$(Get-Date -Format o) listener request error: $($_.Exception.Message)`r`n")
        } finally { if ($client) { $client.Dispose() } }
    }
} catch {
    [IO.File]::AppendAllText($LogFile,"$(Get-Date -Format o) listener fatal error: $($_.Exception.Message)`r`n")
    exit 1
} finally {
    if ($listener) { $listener.Stop() }
    Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
}
