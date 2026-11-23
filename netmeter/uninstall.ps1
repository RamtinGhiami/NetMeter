#requires -Version 5.1
<#
    NetMeter uninstaller (installed by install.ps1 / Setup.exe).

    Usage:
        powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\NetMeter\uninstall.ps1"
        powershell -ExecutionPolicy Bypass -File ...\uninstall.ps1 -PurgeData -Quiet
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [switch]$PurgeData,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$here = $PSScriptRoot

if (-not $InstallDir) {
    if (Test-Path (Join-Path $here "app")) { $InstallDir = $here }
    elseif ($env:LOCALAPPDATA) { $InstallDir = Join-Path $env:LOCALAPPDATA "NetMeter" }
}

if (-not $InstallDir) { Write-Host "[NetMeter] Nothing to uninstall."; exit 0 }

$app  = Join-Path $InstallDir "app"
$venv = Join-Path $InstallDir "venv"
$data = Join-Path $InstallDir "data"

if (-not (Test-Path $app) -and -not (Test-Path $venv)) {
    Write-Host "[NetMeter] NetMeter is not installed in '$InstallDir'." -ForegroundColor Yellow
    exit 0
}

if (-not $Quiet) {
    $ans = Read-Host "Remove NetMeter from '$InstallDir'? (saved usage data is kept unless -PurgeData) [y/N]"
    if ($ans -notmatch '^(y|yes)$') { Write-Host "[NetMeter] Cancelled."; exit 0 }
}

Write-Host "[NetMeter] Stopping running copy..."
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -eq "NetMeter.exe" -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($InstallDir, "OrdinalIgnoreCase")) -or
    ($_.CommandLine -and $_.CommandLine -like "*$InstallDir*" -and $_.CommandLine -like "*run.pyw*")
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

Write-Host "[NetMeter] Removing shortcuts and registry entries..."
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "NetMeter.lnk"
$menuLnk = Join-Path ([Environment]::GetFolderPath("Programs")) "NetMeter.lnk"
$menuDir = Join-Path ([Environment]::GetFolderPath("Programs")) "NetMeter"
Remove-Item -Force $desktopLnk
Remove-Item -Force $menuLnk
Remove-Item -Recurse -Force $menuDir
Remove-Item -Recurse -Force "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NetMeter"
Remove-Item -Recurse -Force "HKCU:\Software\NetMeter"
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "NetMeter"

Write-Host "[NetMeter] Removing program files..."
Remove-Item -Recurse -Force $app
Remove-Item -Recurse -Force $venv

if ($PurgeData) {
    Remove-Item -Recurse -Force $data
} elseif (Test-Path $data) {
    Write-Host "[NetMeter] Usage history kept in: $data"
}

Remove-Item -Force (Join-Path $InstallDir "uninstall.ps1")

if (-not (Test-Path $data)) {
    $left = @(Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) {
        Remove-Item -Force $InstallDir
    } else {
        Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" `
            -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$InstallDir`"" `
            -WindowStyle Hidden
    }
}

Write-Host "[NetMeter] Uninstalled." -ForegroundColor Green
