# Build NetMeter for Windows.
#   powershell -ExecutionPolicy Bypass -File netmeter\build.ps1
#   powershell -ExecutionPolicy Bypass -File netmeter\build.ps1 -NoInstaller
#
# Output:
#   netmeter\dist\NetMeter\NetMeter.exe          portable folder
#   netmeter\dist\NetMeter-Setup-<version>.exe   installer (needs NSIS)
param(
    [switch]$NoInstaller
)

$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$root = Split-Path -Parent $here
Set-Location $root

Write-Host "== NetMeter build ==" -ForegroundColor Cyan

$version = "0.1.0"
$m = Select-String -Path (Join-Path $here "__init__.py") -Pattern '__version__\s*=\s*"([^"]+)"'
if ($m) { $version = $m.Matches[0].Groups[1].Value }

$venv = Join-Path $here ".venv"
$py = Join-Path $venv "Scripts\python.exe"
if (-not (Test-Path $py)) {
    Write-Host "Creating virtual environment..."
    py -3 -m venv $venv
}
& $py -m pip install --upgrade pip | Out-Null
& $py -m pip install -r (Join-Path $here "requirements.txt") pyinstaller

$dist = Join-Path $here "dist"
$work = Join-Path $here "build"
if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
if (Test-Path $work) { Remove-Item -Recurse -Force $work }

# Keep the build small: no Tk, no test tooling, no docs generators.
$pyArgs = @(
    "--noconfirm",
    "--clean",
    "--windowed",
    "--name", "NetMeter",
    "--paths", $root,
    "--add-data", "$here\web;web",
    "--collect-submodules", "netmeter",
    "--exclude-module", "tkinter",
    "--exclude-module", "unittest",
    "--exclude-module", "pydoc",
    "--exclude-module", "doctest",
    "--exclude-module", "pdb",
    "--exclude-module", "xmlrpc",
    "--distpath", $dist,
    "--workpath", $work,
    "--specpath", $work,
    (Join-Path $here "run.pyw")
)
& $py -m PyInstaller @pyArgs
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed" }

$out = Join-Path $dist "NetMeter"
Copy-Item (Join-Path $here "README.md"), (Join-Path $here "NOTICE"), (Join-Path $here "LICENSE") -Destination $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $out "data") | Out-Null

$sizeMb = [math]::Round(((Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host ""
Write-Host "Portable build: $out\NetMeter.exe  ($sizeMb MB)" -ForegroundColor Green

if (-not $NoInstaller) {
    $makensis = $null
    $found = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($found) { $makensis = $found.Source }
    if (-not $makensis) {
        foreach ($candidate in @(
            "$env:ProgramFiles\NSIS\makensis.exe",
            "${env:ProgramFiles(x86)}\NSIS\makensis.exe",
            (Join-Path $env:LOCALAPPDATA "Programs\NSIS\makensis.exe")
        )) {
            if (Test-Path $candidate) { $makensis = $candidate; break }
        }
    }
    if ($makensis) {
        Write-Host "Building Setup.exe with NSIS..."
        Set-Location $here
        & $makensis "/DAPP_VERSION=$version" (Join-Path $here "installer.nsi")
        if ($LASTEXITCODE -ne 0) { throw "NSIS failed" }
        Set-Location $root
        $setup = Join-Path $dist "NetMeter-Setup-$version.exe"
        if (Test-Path $setup) {
            $setupMb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
            Write-Host "Installer:    $setup  ($setupMb MB)" -ForegroundColor Green
        }
    } else {
        Write-Host "NSIS not found - skipped Setup.exe." -ForegroundColor Yellow
        Write-Host "  Install it with:  winget install NSIS.NSIS" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Run without installing:  python -m netmeter"
Write-Host "Install per user:        powershell -ExecutionPolicy Bypass -File netmeter\install.ps1"
