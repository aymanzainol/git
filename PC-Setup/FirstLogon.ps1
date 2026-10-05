<#
    Runs as the user at sign-in (and unlock) until their first sign-in to Outlook has worked, at most
    3 times. Opens classic Outlook first and waits for its Microsoft 365 sign-in, then OneDrive, so
    OneDrive can reuse that sign-in. On a hybrid-joined PC both sign in by themselves.
    Log: %LOCALAPPDATA%\PCSetup-FirstLogon.log
#>
param([string]$OnlyUser)

$flagKey = 'HKCU:\Software\PCSetup'
$log = Join-Path $env:LOCALAPPDATA 'PCSetup-FirstLogon.log'
function Write-FirstLogonLog([string]$Message) { Add-Content -Path $log -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message) }

# Only for the user this PC was set up for (any form: user, DOMAIN\user, domain.com\user, user@domain.com).
$upn = try { "$(whoami.exe /upn 2>$null)".Trim() } catch { '' }
if ($OnlyUser) {
    $short = $OnlyUser -replace '^.*\\', '' -replace '@.*$', ''
    if ($short -ne $env:USERNAME -and -not ($upn -and $OnlyUser -eq $upn)) { exit 0 }
}

$flags = Get-ItemProperty -Path $flagKey -ErrorAction SilentlyContinue
if ($flags.SignInDone) { exit 0 }
$attempt = 1 + [int]$flags.Attempts
if ($attempt -gt 3) { exit 0 }   # don't keep opening apps at every sign-in
if (-not (Test-Path $flagKey)) { New-Item -Path $flagKey -Force | Out-Null }
New-ItemProperty -Path $flagKey -Name Attempts -Value $attempt -PropertyType DWord -Force | Out-Null
Write-FirstLogonLog "First sign-in for $env:USERDOMAIN\$env:USERNAME ($upn), attempt $attempt"

function Set-UserDword([string]$Key, [string]$Name, [int]$Value) {
    if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }   # -Force on an existing key would empty it
    New-ItemProperty -Path $Key -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}
# Same settings as the default profile, for a profile that existed before setup.
Set-UserDword 'HKCU:\Software\Microsoft\Office\16.0\Outlook\AutoDiscover' 'ZeroConfigExchange' 1
Set-UserDword 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General' 'HideNewOutlookToggle' 1

function Get-DsregStatus {
    $status = @{}
    foreach ($line in @(dsregcmd.exe /status 2>$null)) {
        if ($line -match '^\s*([\w ]+?)\s*:\s*(.*?)\s*$' -and -not $status.ContainsKey($Matches[1])) { $status[$Matches[1]] = $Matches[2] }
    }
    $status
}

# On a hybrid-joined PC the Microsoft 365 token (PRT) arrives shortly after sign-in - give it a moment.
$ds = Get-DsregStatus
if ($ds['AzureAdJoined'] -eq 'YES' -and $ds['AzureAdPrt'] -ne 'YES') {
    $deadline = (Get-Date).AddMinutes(5)
    while ($ds['AzureAdPrt'] -ne 'YES' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 15; $ds = Get-DsregStatus }
}
Write-FirstLogonLog ('Microsoft 365 sign-in state: AzureAdJoined={0} AzureAdPrt={1} WorkplaceJoined={2}' -f $ds['AzureAdJoined'], $ds['AzureAdPrt'], $ds['WorkplaceJoined'])

$session = (Get-Process -Id $PID).SessionId
function Test-Running([string]$Name) { [bool](Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }) }

# 1. Classic Outlook - signs in to Microsoft 365 and builds the mail profile.
$outlook = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE' -ErrorAction SilentlyContinue).'(default)'
if (-not $outlook -or -not (Test-Path $outlook)) {
    $outlook = @("$env:ProgramFiles\Microsoft Office\root\Office16\OUTLOOK.EXE", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OUTLOOK.EXE") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $outlook) { Write-FirstLogonLog 'Classic Outlook not found'; exit 0 }
if (-not (Test-Running 'OUTLOOK')) { Start-Process -FilePath $outlook }
Write-FirstLogonLog "Classic Outlook started: $outlook"

function Test-OfficeSignedIn {
    [bool](Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities' -ErrorAction SilentlyContinue |
        ForEach-Object { (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).EmailAddress } | Where-Object { $_ })
}
$deadline = (Get-Date).AddMinutes(20)
while (-not (Test-OfficeSignedIn) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
$officeOk = Test-OfficeSignedIn
Write-FirstLogonLog "Office signed in to Microsoft 365: $officeOk"

# 2. OneDrive - after Office, so it can use the same sign-in. It installs itself per user at the first
#    sign-in, so wait for it, and restart it if it already tried (and failed) before Outlook was signed in.
$deadline = (Get-Date).AddMinutes(5)
do {
    $oneDrive = @("$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $oneDrive) { Start-Sleep -Seconds 10 }
} until ($oneDrive -or (Get-Date) -gt $deadline)
$odAccount = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Business1'
function Test-OneDriveSignedIn { [bool](Get-ItemProperty -Path $odAccount -ErrorAction SilentlyContinue).UserEmail }
if (-not $oneDrive) {
    Write-FirstLogonLog 'OneDrive not found'
} elseif (-not (Test-OneDriveSignedIn)) {
    while (Get-Process -Name OneDriveSetup -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }) { Start-Sleep -Seconds 5 }
    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } | Stop-Process -Force
    Start-Sleep -Seconds 2
    Start-Process -FilePath $oneDrive -ArgumentList '/background'
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-OneDriveSignedIn) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    Write-FirstLogonLog "OneDrive started: $oneDrive - signed in: $(Test-OneDriveSignedIn)"
} else {
    Write-FirstLogonLog 'OneDrive already signed in'
}

if ($officeOk) {
    New-ItemProperty -Path $flagKey -Name SignInDone -Value 1 -PropertyType DWord -Force | Out-Null
    Write-FirstLogonLog 'Done'
} else {
    Write-FirstLogonLog 'Outlook sign-in not finished yet - will try again at the next sign-in or unlock'
}
