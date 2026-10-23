<#
.SYNOPSIS
    Register the relay so it starts automatically and stays alive.

.DESCRIPTION
    On the machine that runs your MCP client (the "workstation"):
      1. writes relay configuration to <InstallRoot>\relay.env.cmd
      2. registers a logon task for the relay itself
      3. registers a 5-minute watchdog that restarts the relay if it dies

    The relay is what makes the whole thing survive target IP changes and
    target-side restarts, so it must be supervised just like the target
    instances are.

.EXAMPLE
    .\install-relay.ps1 -Targets 'DESKTOP-ABC:8090,DESKTOP-ABC:8095' -AuthKey 'xxxx'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Targets,

    [Parameter(Mandatory = $true)]
    [string] $AuthKey,

    [string] $Listen     = '127.0.0.1:8091',
    [int]    $TimeoutMs  = 60000,
    [string] $NodeExe    = '',
    [string] $InstallRoot = 'C:\ProgramData\winremote-relay'
)

$ErrorActionPreference = 'Stop'
function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    $m" -ForegroundColor Green }

if (-not $NodeExe) {
    $NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
}
if (-not $NodeExe) { throw 'Node.js 18+ not found. Install it or pass -NodeExe C:\path\node.exe' }
Write-Ok "node: $NodeExe"

$relay = Join-Path $PSScriptRoot 'winremote-relay.js'
if (-not (Test-Path $relay)) { throw "winremote-relay.js not found next to this script ($relay)" }

Write-Step "Preparing $InstallRoot"
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
Copy-Item $relay (Join-Path $InstallRoot 'winremote-relay.js') -Force

$startCmd = Join-Path $InstallRoot 'start-relay.cmd'
$cmdLines = @(
    '@echo off',
    ('"' + $NodeExe + '" "' + (Join-Path $InstallRoot 'winremote-relay.js') +
     '" --listen ' + $Listen +
     ' --target ' + $Targets +
     ' --auth-key ' + $AuthKey +
     ' --timeout ' + $TimeoutMs +
     ' >> "' + $InstallRoot + '\relay.out.log" 2>> "' + $InstallRoot + '\relay.err.log"')
)
Set-Content -Path $startCmd -Value $cmdLines -Encoding ASCII
Write-Ok "launcher: $startCmd"

# key file, ACL-restricted
$keyFile = Join-Path $InstallRoot 'authkey.txt'
Set-Content -Path $keyFile -Value $AuthKey -Encoding ASCII -NoNewline
icacls $keyFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null

# hidden logon entry
$vbs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp\winremote-relay.vbs'
$vbsLines = @(
    "' starts the winremote relay without a console window",
    'Set sh = CreateObject("WScript.Shell")',
    ('sh.Run "cmd /c ""' + $startCmd + '""", 0, False')
)
Set-Content -Path $vbs -Value $vbsLines -Encoding ASCII
Write-Ok "logon autostart: $vbs"

# watchdog
$watchdog = Join-Path $InstallRoot 'relay-watchdog.ps1'
$port = $Listen.Substring($Listen.LastIndexOf(':') + 1)
$watchLines = @(
    '# Restarts the relay when its port stops listening.',
    '$ErrorActionPreference = ''SilentlyContinue''',
    ('$cmd = ''' + $startCmd + ''''),
    ('$log = ''' + (Join-Path $InstallRoot 'relay.log') + ''''),
    ('if (-not (Get-NetTCPConnection -LocalPort ' + $port + ' -State Listen -ErrorAction SilentlyContinue)) {'),
    ('    Add-Content $log ((Get-Date -Format s) + ''  relay ' + $port + ' down -> start'')'),
    ('    Start-Process ''cmd.exe'' -ArgumentList (''/c ""'' + $cmd + ''""'') -WindowStyle Hidden'),
    '}'
)
Set-Content -Path $watchdog -Value $watchLines -Encoding UTF8

$watchTr = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $watchdog + '"'
schtasks /Create /SC MINUTE /MO 5 /TN winremote-relay-watchdog /TR $watchTr /RL HIGHEST /F | Out-Null
Write-Ok 'task winremote-relay-watchdog'

# start now
Start-Process 'cmd.exe' -ArgumentList ('/c "' + $startCmd + '"') -WindowStyle Hidden
Start-Sleep -Seconds 3

$healthy = $false
try { $healthy = (Invoke-RestMethod -Uri ('http://' + $Listen + '/health') -TimeoutSec 5).status -eq 'ok' } catch { }
Write-Host ''
Write-Host '==================== relay installed ====================' -ForegroundColor Green
Write-Host ("  client URL : http://{0}/mcp" -f $Listen)
Write-Host ("  targets    : {0}" -f $Targets)
Write-Host ("  health     : {0}" -f $(if ($healthy) { 'ok' } else { 'NOT reachable - check ' + $InstallRoot + '\relay.err.log' }))
Write-Host ''
Write-Host '  Configure your MCP client with exactly that client URL.'
Write-Host '========================================================'
Write-Host ''
