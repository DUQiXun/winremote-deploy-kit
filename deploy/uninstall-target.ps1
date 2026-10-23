<#
.SYNOPSIS
    Remove everything install-target.ps1 created.
.DESCRIPTION
    Deletes scheduled tasks, the logon autostart entry, firewall rules and the
    install directory. Does NOT uninstall the winremote-mcp pip package unless
    -RemovePackage is given. Running instances are stopped.
#>
[CmdletBinding()]
param(
    [int]    $Port        = 8090,
    [int]    $SystemPort  = 8095,
    [string] $InstallRoot = 'C:\ProgramData\winremote',
    [switch] $RemovePackage
)

$ErrorActionPreference = 'Continue'
function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}

Write-Step 'Removing scheduled tasks'
foreach ($t in @('winremote-boot', 'winremote-watchdog', 'WinRemoteMCP', 'WinRemoteWatchdog')) {
    schtasks /Delete /TN $t /F 2>$null | Out-Null
    Write-Host "    $t"
}

Write-Step 'Removing logon autostart'
$vbs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp\winremote.vbs'
if (Test-Path $vbs) { Remove-Item $vbs -Force; Write-Host "    $vbs" }

Write-Step 'Stopping instances'
$current = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).OwningProcess
if ($current) { Stop-Process -Id $current -Force -ErrorAction SilentlyContinue; Write-Host "    stopped PID $current (port $Port)" }
$current2 = (Get-NetTCPConnection -LocalPort $SystemPort -State Listen -ErrorAction SilentlyContinue).OwningProcess
if ($current2) { Stop-Process -Id $current2 -Force -ErrorAction SilentlyContinue; Write-Host "    stopped PID $current2 (port $SystemPort)" }

Write-Step 'Removing firewall rules'
foreach ($p in @($Port, $SystemPort)) {
    $rule = "winremote-mcp $p"
    if (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $rule
        Write-Host "    $rule"
    }
}

Write-Step "Removing $InstallRoot"
if (Test-Path $InstallRoot) { Remove-Item $InstallRoot -Recurse -Force; Write-Host "    removed" }

if ($RemovePackage) {
    Write-Step 'Uninstalling winremote-mcp pip package'
    foreach ($launcher in @('py', 'python')) {
        if (Get-Command $launcher -ErrorAction SilentlyContinue) {
            & $launcher -3 -m pip uninstall -y winremote-mcp 2>$null
            break
        }
    }
}

Write-Host ''
Write-Host 'Done. Note: the sleep/hibernate changes are NOT reverted (they are'
Write-Host 'machine-wide power settings). Restore with:'
Write-Host '  powercfg /change standby-timeout-ac 30'
Write-Host '  powercfg /change hibernate-timeout-ac 180'
Write-Host ''
