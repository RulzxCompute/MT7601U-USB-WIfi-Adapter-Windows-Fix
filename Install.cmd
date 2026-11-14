@echo off
setlocal
cd /d "%~dp0"

fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting administrator rights...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Installing the MT7601U driver and USB descriptor fix...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-MT7601U.ps1"
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo Installation finished.
) else (
    echo Installation finished with errors. See the log in %TEMP%\MT7601U_Install.log
)
echo.
pause
exit /b %RC%
