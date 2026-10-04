@echo off
:: New PC setup - double-click this file.
:: Asks for admin rights, then runs Setup-NewPC.ps1.
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-NewPC.ps1" %*
