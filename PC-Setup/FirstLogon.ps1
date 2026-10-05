<#
    Runs once per user at their first sign-in after setup (scheduled task, normal user rights).
    Starts OneDrive (it signs in with the Windows account) and classic Outlook (it builds the
    mail profile from the signed-in account). Log: %LOCALAPPDATA%\PCSetup-FirstLogon.log
#>
param([string]$OnlyUser)

$flagKey = 'HKCU:\Software\PCSetup'
$log = Join-Path $env:LOCALAPPDATA 'PCSetup-FirstLogon.log'
function Write-FirstLogonLog([string]$Message) { Add-Content -Path $log -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message) }

if ($OnlyUser) {
    $me = @($env:USERNAME, "$env:USERDOMAIN\$env:USERNAME")
    try { $me += (whoami.exe /upn 2>$null) } catch { }
    if ($me -notcontains $OnlyUser) { exit 0 }
}
if ((Get-ItemProperty -Path $flagKey -ErrorAction SilentlyContinue).FirstLogonDone) { exit 0 }
Write-FirstLogonLog "First sign-in for $env:USERDOMAIN\$env:USERNAME"

# Same settings as the default profile, for a profile that existed before setup.
foreach ($s in @(
        @{ Key = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover';    Name = 'ZeroConfigExchange' }
        @{ Key = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General'; Name = 'HideNewOutlookToggle' })) {
    New-Item -Path $s.Key -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $s.Key -Name $s.Name -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
}

# OneDrive installs itself per user during the first sign-in; give it a few minutes.
$deadline = (Get-Date).AddMinutes(5)
do {
    $oneDrive = @("$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $oneDrive) { Start-Sleep -Seconds 10 }
} until ($oneDrive -or (Get-Date) -gt $deadline)
if ($oneDrive) {
    if (-not (Get-Process -Name OneDrive -ErrorAction SilentlyContinue)) { Start-Process -FilePath $oneDrive -ArgumentList '/background' }
    Write-FirstLogonLog "OneDrive started: $oneDrive"
} else {
    Write-FirstLogonLog 'OneDrive not found'
}

Start-Sleep -Seconds 15
$outlook = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE' -ErrorAction SilentlyContinue).'(default)'
if ($outlook -and (Test-Path $outlook)) {
    Start-Process -FilePath $outlook
    Write-FirstLogonLog "Classic Outlook started: $outlook"
} else {
    Write-FirstLogonLog 'Classic Outlook not found'
}

New-Item -Path $flagKey -Force | Out-Null
New-ItemProperty -Path $flagKey -Name FirstLogonDone -Value 1 -PropertyType DWord -Force | Out-Null
