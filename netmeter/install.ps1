#requires -Version 5.1
<#
    NetMeter installer - per user, no admin rights, no leftovers in Program Files.

    Usage (from the project folder):
        powershell -ExecutionPolicy Bypass -File netmeter\install.ps1
        powershell -ExecutionPolicy Bypass -File netmeter\install.ps1 -Autostart -Start
        powershell -ExecutionPolicy Bypass -File netmeter\install.ps1 -InstallDir "D:\Apps\NetMeter"

    If netmeter\dist\NetMeter\NetMeter.exe exists it installs that portable build
    (fast, no Python needed). Otherwise it installs from the Python sources into a
    private virtual environment under the install folder.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "NetMeter"),
    [string]$Python = "",
    [switch]$Autostart,
    [switch]$NoShortcut,
    [switch]$Start
)

$ErrorActionPreference = "Stop"

$here    = $PSScriptRoot
$app     = Join-Path $InstallDir "app"
$data    = Join-Path $InstallDir "data"
$venv    = Join-Path $InstallDir "venv"
$venvPy  = Join-Path $venv "Scripts\python.exe"
$venvPyw = Join-Path $venv "Scripts\pythonw.exe"

function Write-Step([string]$msg) { Write-Host "[NetMeter] $msg" -ForegroundColor Cyan }
function Stop-With([string]$msg) { Write-Host "[NetMeter] $msg" -ForegroundColor Red; exit 1 }

if ($app.StartsWith($here, "OrdinalIgnoreCase")) {
    Stop-With "Choose an install folder outside '$here'."
}

$version = "0.1.0"
$initPy = Join-Path $here "__init__.py"
if (Test-Path $initPy) {
    $m = Select-String -Path $initPy -Pattern '__version__\s*=\s*"([^"]+)"'
    if ($m) { $version = $m.Matches[0].Groups[1].Value }
}

Write-Step "Installing NetMeter $version into $InstallDir"

# ---- stop the copy that belongs to this install folder ----------------------
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -eq "NetMeter.exe" -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($InstallDir, "OrdinalIgnoreCase")) -or
    ($_.CommandLine -and $_.CommandLine -like "*$InstallDir*" -and $_.CommandLine -like "*run.pyw*")
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 400

if (Test-Path $app) { Remove-Item -Recurse -Force $app }
New-Item -ItemType Directory -Force -Path $app, $data | Out-Null

# ---- program files ---------------------------------------------------------
$target = ""
$arguments = ""
$icon = ""
$exeDist = Join-Path $here "dist\NetMeter\NetMeter.exe"

if (Test-Path $exeDist) {
    Write-Step "Copying the portable build"
    robocopy (Join-Path $here "dist\NetMeter") $app /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Stop-With "Copy failed (robocopy exit $LASTEXITCODE)." }
    $target = Join-Path $app "NetMeter.exe"
    $arguments = '--no-browser --data-dir "' + $data + '"'
    $icon = $target
} else {
    Write-Step "No portable build found -> installing from Python sources"

    if ($Python) {
        if (-not (Test-Path $Python)) { Stop-With "Python not found: $Python" }
        $pyExe = (Resolve-Path $Python).Path
    } else {
        $pyExe = ""
        $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
        if ($launcher) {
            $out = & py.exe -3 -c "import sys;print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) { $pyExe = ($out | Select-Object -First 1).Trim() }
        }
        if (-not $pyExe) {
            $p = Get-Command python.exe -ErrorAction SilentlyContinue
            if ($p) { $pyExe = $p.Source }
        }
        if (-not $pyExe) {
            Stop-With "Python 3 not found. Install it from python.org, or run netmeter\build.ps1 first."
        }
    }

    if (-not (Test-Path $venvPy)) {
        Write-Step "Creating a private virtual environment"
        & $pyExe -m venv $venv
        if ($LASTEXITCODE -ne 0) { Stop-With "Could not create the virtual environment." }
    }

    Write-Step "Installing dependencies"
    & $venvPy -m pip install --disable-pip-version-check --quiet --upgrade pip
    & $venvPy -m pip install --disable-pip-version-check --quiet -r (Join-Path $here "requirements.txt")
    if ($LASTEXITCODE -ne 0) { Stop-With "Dependency installation failed." }

    Write-Step "Copying application files"
    $rcArgs = @(
        $here,
        (Join-Path $app "netmeter"),
        "/E",
        "/XD", "__pycache__", "dist", "build", ".venv", "data", ".git",
        "/XF", "*.pyc", "install.ps1", "uninstall.ps1", "installer.nsi", "build.ps1",
        "/NFL", "/NDL", "/NJH", "/NJS", "/NP"
    )
    & robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { Stop-With "Copy failed (robocopy exit $LASTEXITCODE)." }

    $target = $venvPyw
    $arguments = '"' + (Join-Path $app "netmeter\run.pyw") + '" --no-browser --data-dir "' + $data + '"'
    $icon = $venvPyw
}

# ---- shortcuts -------------------------------------------------------------
if (-not $NoShortcut) {
    Write-Step "Creating shortcuts"
    $shell = New-Object -ComObject WScript.Shell
    $links = @(
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "NetMeter.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Programs")) "NetMeter.lnk")
    )
    foreach ($lnk in $links) {
        $sc = $shell.CreateShortcut($lnk)
        $sc.TargetPath = $target
        $sc.Arguments = $arguments
        $sc.WorkingDirectory = $app
        $sc.Description = "NetMeter - per-device internet usage monitor"
        if ($icon) { $sc.IconLocation = $icon }
        $sc.Save()
    }
}

# ---- uninstaller + registry ------------------------------------------------
Copy-Item (Join-Path $here "uninstall.ps1") (Join-Path $InstallDir "uninstall.ps1") -Force
$uninstaller = Join-Path $InstallDir "uninstall.ps1"

$sizeKb = 0
Get-ChildItem $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
    ForEach-Object { $sizeKb += $_.Length }
$sizeKb = [int]($sizeKb / 1KB)

$key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NetMeter"
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name "DisplayName" -Value "NetMeter"
Set-ItemProperty -Path $key -Name "DisplayVersion" -Value $version
Set-ItemProperty -Path $key -Name "Publisher" -Value "NetMeter"
Set-ItemProperty -Path $key -Name "InstallLocation" -Value $InstallDir
Set-ItemProperty -Path $key -Name "DisplayIcon" -Value $target
Set-ItemProperty -Path $key -Name "UninstallString" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstaller`""
Set-ItemProperty -Path $key -Name "QuietUninstallString" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstaller`" -Quiet"
New-ItemProperty -Path $key -Name "NoModify" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $key -Name "NoRepair" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $key -Name "EstimatedSize" -Value $sizeKb -PropertyType DWord -Force | Out-Null

# ---- optional autostart ----------------------------------------------------
if ($Autostart) {
    Write-Step "Enabling start with Windows"
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name "NetMeter" -Value ('"' + $target + '" ' + $arguments)
}

Write-Host ""
Write-Host "[NetMeter] Installed." -ForegroundColor Green
Write-Host "  program : $app"
Write-Host "  data    : $data"
if (-not $NoShortcut) { Write-Host "  shortcuts: Desktop and Start Menu" }
Write-Host "  uninstall: Windows Settings > Apps, or:"
Write-Host "             powershell -ExecutionPolicy Bypass -File `"$uninstaller`""

if ($Start) {
    Start-Process -FilePath $target -ArgumentList $arguments
    Write-Host "  started the dashboard in your browser"
}
