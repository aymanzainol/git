@echo off
:: For a PC that is already on the domain: set up the user's first sign-in
:: (one-time automatic sign-in, classic Outlook, OneDrive), then restart.
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-NewPC.ps1" -SetupUser
