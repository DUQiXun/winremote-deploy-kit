<#
.SYNOPSIS
    Install winremote-mcp as a durable remote-control endpoint on a Windows host.

.DESCRIPTION
    Creates two channels:

      -Port       (default 8090) interactive instance, started at logon inside
                  the logged-on user's session. Required for screenshot / mouse
                  / keyboard tools.

      -SystemPort (default 8095) headless instance, started at boot as SYSTEM.
                  Available even when nobody is logged in: command / file /
                  registry / service / process tools work, GUI tools do not.

    Also installs firewall rules, a 5-minute watchdog, and (optionally) power
    settings so the machine does not fall asleep.

    Run ON the machine you want to control, from an elevated PowerShell.

.PARAMETER AuthKey
    Bearer token shared with the client. Generated automatically when omitted
    and written to <InstallRoot>\authkey.txt (ACL-restricted).

.EXAMPLE
    .\install-target.ps1

.EXAMPLE
    .\install-target.ps1 -Port 8090 -SystemPort 8095 -NoPowerTweaks
#>
[CmdletBinding()]
param(
    [int]    $Port        = 8090,
    [int]    $SystemPort  = 8095,
    [string] $AuthKey     = '',
    [string] $PythonExe   = '',
    [string] $InstallRoot = 'C:\ProgramData\winremote',
    [switch] $NoSystemChannel,
    [switch] $NoPowerTweaks,
    [switch] $SkipPipInstall
)

$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    $m" -ForegroundColor Green }

# --------------------------------------------------------------- preconditions

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}

# ------------------------------------------------------------------ interpreter

Write-Step 'Locating python.exe'
if (-not $PythonExe) {
    $candidates = @()
    foreach ($launcher in @('py', 'python')) {
        if (-not (Get-Command $launcher -ErrorAction SilentlyContinue)) { continue }
        try {
            $arg = if ($launcher -eq 'py') { '-3' } else { '' }
            $out = & $launcher $arg -c "import sys;print(sys.executable)" 2>$null
            if ($out) { $candidates += ($out | Select-Object -First 1).Trim() }
        } catch { }
    }
    foreach ($p in @(
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        'C:\Python313\python.exe', 'C:\Python312\python.exe', 'C:\Python311\python.exe'
    )) { if (Test-Path $p) { $candidates += $p } }
    $PythonExe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $PythonExe -or -not (Test-Path $PythonExe)) {
    throw 'python.exe not found. Install Python 3.10+ or pass -PythonExe C:\path\to\python.exe'
}
$pyVer = & $PythonExe -c "import sys;print('%d.%d' % sys.version_info[:2])"
Write-Ok "$PythonExe (Python $pyVer)"
if ([version]$pyVer -lt [version]'3.10') { throw "Python $pyVer is too old: winremote-mcp requires >= 3.10" }

# ---------------------------------------------------------------------- package

if (-not $SkipPipInstall) {
    Write-Step 'Installing / verifying winremote-mcp'
    & $PythonExe -m pip install --disable-pip-version-check -q -U winremote-mcp
    $show = & $PythonExe -m pip show winremote-mcp 2>$null
    if (-not $show) { throw 'winremote-mcp installation failed' }
    Write-Ok (($show | Select-String '^Version:').Line.Trim())
}

# --------------------------------------------------------------------- auth key

if (-not $AuthKey) {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $AuthKey = ([Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]', '').Substring(0, 32)
    Write-Ok 'generated a new auth key (shown at the end)'
}

# ------------------------------------------------------------------ install dir

Write-Step "Preparing $InstallRoot"
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

$keyFile = Join-Path $InstallRoot 'authkey.txt'
Set-Content -Path $keyFile -Value $AuthKey -Encoding ASCII -NoNewline
icacls $keyFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
Write-Ok "auth key -> $keyFile (ACL: Administrators + SYSTEM only)"

$startCmd   = Join-Path $InstallRoot 'start-interactive.cmd'
$watchdogPs = Join-Path $InstallRoot 'watchdog.ps1'
$startupVbs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp\winremote.vbs'

# --- launcher (plain cmd, no quoting games) ---------------------------------
$cmdLines = @(
    '@echo off',
    'rem Interactive instance: runs inside the logged-on desktop session.',
    ('"' + $PythonExe + '" -m winremote --host 0.0.0.0 --port ' + $Port +
     ' --auth-key ' + $AuthKey + ' --enable-tier3' +
     ' >> "' + $InstallRoot + '\interactive.out.log" 2>> "' + $InstallRoot + '\interactive.err.log"')
)
Set-Content -Path $startCmd -Value $cmdLines -Encoding ASCII
Write-Ok "launcher: $startCmd"

# --- hidden logon entry ------------------------------------------------------
$vbsLine = 'sh.Run "cmd /c ""' + $startCmd + '""", 0, False'
$vbsLines = @(
    "' starts the interactive winremote-mcp instance without a console window",
    'Set sh = CreateObject("WScript.Shell")',
    $vbsLine
)
Set-Content -Path $startupVbs -Value $vbsLines -Encoding ASCII
Write-Ok "logon autostart: $startupVbs"

# --- watchdog ----------------------------------------------------------------
$watchdogLines = @(
    '# Restarts a winremote-mcp instance whose port stopped listening.',
    '$ErrorActionPreference = ''SilentlyContinue''',
    ('$vbs = ''' + $startupVbs + ''''),
    ('$log = ''' + (Join-Path $InstallRoot 'watchdog.log') + ''''),
    '',
    'if (-not (Get-NetTCPConnection -LocalPort ' + $Port + ' -State Listen -ErrorAction SilentlyContinue)) {',
    ('    Add-Content $log ((Get-Date -Format s) + ''  interactive ' + $Port + ' down -> start'')'),
    ('    Start-Process ''wscript.exe'' -ArgumentList (''//B ""'' + $vbs + ''""'') -WindowStyle Hidden'),
    '}'
)
if (-not $NoSystemChannel) {
    $watchdogLines += @(
        '',
        'if (-not (Get-NetTCPConnection -LocalPort ' + $SystemPort + ' -State Listen -ErrorAction SilentlyContinue)) {',
        ('    Add-Content $log ((Get-Date -Format s) + ''  system ' + $SystemPort + ' down -> start'')'),
        '    Start-Process ''schtasks.exe'' -ArgumentList ''/Run'',''/TN'',''winremote-boot'' -WindowStyle Hidden',
        '}'
    )
}
Set-Content -Path $watchdogPs -Value $watchdogLines -Encoding UTF8
Write-Ok "watchdog: $watchdogPs"

# ------------------------------------------------------------------- firewall

Write-Step 'Opening firewall ports'
$allPorts = @($Port)
if (-not $NoSystemChannel) { $allPorts += $SystemPort }
foreach ($p in $allPorts) {
    $rule = "winremote-mcp $p"
    if (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue) {
        Write-Ok "rule exists: $rule"
    } else {
        New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort $p -Action Allow -Profile Any | Out-Null
        Write-Ok "rule added: $rule"
    }
}

# --------------------------------------------------------------- boot channel

if (-not $NoSystemChannel) {
    Write-Step "Creating boot-time SYSTEM channel on port $SystemPort"
    $tr = '"' + $PythonExe + '" -m winremote --host 0.0.0.0 --port ' + $SystemPort + ' --auth-key ' + $AuthKey + ' --enable-tier3'
    schtasks /Create /SC ONSTART /TN winremote-boot /RU SYSTEM /RL HIGHEST /TR $tr /F | Out-Null
    schtasks /Run /TN winremote-boot | Out-Null
    Write-Ok 'task winremote-boot (ONSTART / SYSTEM)'
}

# ------------------------------------------------------------------- watchdog

Write-Step 'Registering watchdog task (every 5 minutes)'
$watchdogTr = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $watchdogPs + '"'
schtasks /Create /SC MINUTE /MO 5 /TN winremote-watchdog /TR $watchdogTr /RL HIGHEST /F | Out-Null
Write-Ok 'task winremote-watchdog'

# ---------------------------------------------------------------------- power

if (-not $NoPowerTweaks) {
    Write-Step 'Disabling sleep / hibernate so the endpoint stays reachable'
    powercfg /change standby-timeout-ac 0  | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
    powercfg /hibernate off 2>$null | Out-Null
    Write-Ok 'sleep and hibernate disabled (AC)'
}

# ------------------------------------------------------------------- finalize

Write-Step 'Starting the interactive instance'
Start-Process 'wscript.exe' -ArgumentList ('//B "' + $startupVbs + '"') -WindowStyle Hidden
Start-Sleep -Seconds 4

$hostName = $env:COMPUTERNAME
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        Select-Object -First 1).IPAddress

Write-Host ''
Write-Host '==================== winremote-mcp installed ====================' -ForegroundColor Green
Write-Host "  host        : $hostName ($ip)"
Write-Host "  interactive : http://${hostName}:$Port/mcp     (logon session, GUI tools)"
if (-not $NoSystemChannel) {
    Write-Host "  always-on   : http://${hostName}:$SystemPort/mcp     (boot/SYSTEM, command tools)"
}
Write-Host "  auth key    : $AuthKey"
Write-Host "  key file    : $keyFile"
Write-Host ''
foreach ($p in $allPorts) {
    $up = (Test-NetConnection -ComputerName 127.0.0.1 -Port $p -WarningAction SilentlyContinue).TcpTestSucceeded
    Write-Host ("  port {0} : {1}" -f $p, $(if ($up) { 'listening' } else { 'NOT listening (inspect logs in ' + $InstallRoot + ')' }))
}
Write-Host ''
Write-Host '  Next: point your MCP client at relay/winremote-relay.js (recommended)'
Write-Host '        or directly at one of the URLs above.'
Write-Host '================================================================='
Write-Host ''
