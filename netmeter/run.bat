@echo off
chcp 65001 >nul
cd /d "%~dp0.."
where pyw >nul 2>nul
if %errorlevel%==0 (
    start "" pyw -3 "netmeter\run.pyw"
) else (
    where pythonw >nul 2>nul
    if %errorlevel%==0 (
        start "" pythonw "netmeter\run.pyw"
    ) else (
        py -3 -m netmeter
    )
)
