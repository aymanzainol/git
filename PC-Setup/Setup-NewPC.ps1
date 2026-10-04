#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up a new company PC end to end:
      1. Windows Update (repeats and reboots until nothing is left)
      2. Microsoft Store / winget app updates
      3. Company programs (Chrome, Foxit, WinRAR, Microsoft 365, Keyloop Drive, CrowdStrike)
      4. Domain join (with optional rename)

.DESCRIPTION
    Run it once as a local administrator (double-click Start-Setup.cmd).
    It asks everything it needs up front, then runs unattended. When Windows
    Update needs a restart, the PC reboots; log back in with the same account
    and the script carries on by itself. Progress lives in
    C:\ProgramData\PCSetup (state.xml, setup.log).

.PARAMETER Resume
    Used by the scheduled task after a reboot. You don't need to pass it.

.PARAMETER SkipWindowsUpdate
    Go straight to app updates / installs.

.PARAMETER SkipDomainJoin
    Do everything except the domain join.

.PARAMETER Unattended
    No questions and no restart prompt at the end (keeps the current PC name).
    For testing in Windows Sandbox or CI. Exit code 2 = something failed.
#>
[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipDomainJoin,
    [switch]$Unattended
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$WorkDir   = Join-Path $env:ProgramData 'PCSetup'
$KitDir    = Join-Path $WorkDir 'kit'
$StateFile = Join-Path $WorkDir 'state.xml'
$CredFile  = Join-Path $WorkDir 'domain-cred.xml'
$LogFile   = Join-Path $WorkDir 'setup.log'
$TaskName  = 'PCSetup-Resume'
$Stages    = @('WindowsUpdate', 'StoreUpdates', 'Apps', 'DomainJoin', 'Done')

# winget exit codes that still mean "fine"
$WingetOk = @(
    0
    -1978335135   # 0x8A150061 package already installed
    -1978335189   # 0x8A15002B no applicable update
    -1978334967   # 0x8A150109 installed, reboot required to finish
    -1978334966   # 0x8A15010A installed, reboot required
)
$InstallerOk = @(0, 3010, 1641)   # 3010/1641 = success, reboot required

#region Helpers -----------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet('Info', 'Step', 'Ok', 'Warn', 'Error')][string]$Level = 'Info')
    $colors = @{ Info = 'Gray'; Step = 'Cyan'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red' }
    $prefix = @{ Info = '   '; Step = '==>'; Ok = ' + '; Warn = ' ! '; Error = ' X ' }
    $line = '{0} {1}' -f $prefix[$Level], $Message
    Write-Host $line -ForegroundColor $colors[$Level]
    Add-Content -Path $LogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $line) -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-NotConfigured([string]$Value) { $Value -match 'CHANGE-ME' }

function New-State {
    @{
        Stage             = 'WindowsUpdate'
        UpdateRound       = 0
        ComputerName      = $null
        DomainName        = $null
        SkipWindowsUpdate = [bool]$SkipWindowsUpdate
        SkipDomainJoin    = [bool]($SkipDomainJoin -or $Unattended)
        Unattended        = [bool]$Unattended
        Results           = @()
        StartedAt         = Get-Date
    }
}

function Save-State($State) { $State | Export-Clixml -Path $StateFile -Force }

function Add-Result($State, [string]$Item, [string]$Result) {
    $State.Results = @($State.Results | Where-Object { $_.Item -ne $Item }) + [pscustomobject]@{ Item = $Item; Result = $Result }
    Save-State $State
}

function Set-NextStage($State) {
    $State.Stage = $Stages[[array]::IndexOf($Stages, $State.Stage) + 1]
    Save-State $State
}

function Wait-ForInternet {
    for ($i = 0; $i -lt 24; $i++) {
        try {
            $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5
            if ($r.Content -like 'Microsoft Connect Test*') { return }
        } catch { }
        if ($i -eq 0) { Write-Log 'Waiting for an internet connection...' }
        Start-Sleep -Seconds 5
    }
    throw 'No internet connection after 2 minutes. Connect the PC to the network and run Start-Setup.cmd again.'
}

function Restart-AndResume($State, [string]$Reason) {
    Save-State $State
    Write-Log "Restarting ($Reason)." 'Step'
    Write-Log "Log back in as '$env:USERNAME' and setup will continue automatically." 'Warn'
    for ($i = 15; $i -gt 0; $i--) { Write-Host "`r    Restarting in $i s... (Ctrl+C to cancel) " -NoNewline; Start-Sleep 1 }
    Write-Host ''
    try { Stop-Transcript | Out-Null } catch { }
    Restart-Computer -Force
    exit 0
}

function Register-ResumeTask {
    $script    = Join-Path $KitDir 'Setup-NewPC.ps1'
    $user      = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Resume"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

function Unregister-ResumeTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Initialize-PSGallery {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $nuget = Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]'2.8.5.201' }
    if (-not $nuget) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null }
}

function Import-GalleryModule([string]$Name) {
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Log "Installing PowerShell module $Name..."
        Initialize-PSGallery
        Install-Module -Name $Name -Repository PSGallery -Scope AllUsers -Force -AllowClobber
    }
    Import-Module $Name -Force
}

function Invoke-Native([string]$File, [string[]]$Arguments) {
    # Streams output to the screen and log, dropping winget's spinner/progress-bar noise.
    & $File @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_.Trim() -and $_.Trim() -notmatch '^[-\\|/]$' -and $_ -notmatch '[KMG]B /' -and $_ -notmatch '^\W+\d+%$' } |
        ForEach-Object { Write-Log $_.Trim() }
    return $LASTEXITCODE
}

function Find-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]($_.Directory.Name -split '_')[1] } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if ($exe) { return $exe.FullName }
}

function Test-WingetUsable([string]$Exe) {
    if (-not $Exe) { return $false }
    try {
        $v = (& $Exe --version 2>$null | Select-Object -First 1) -replace '[^\d\.]', ''
        return ([version]$v -ge [version]'1.6')
    } catch { return $false }
}

function Get-Winget {
    $exe = Find-Winget
    if (Test-WingetUsable $exe) { return $exe }

    Write-Log 'winget is missing or out of date - installing it...'
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { }
    $exe = Find-Winget
    if (Test-WingetUsable $exe) { return $exe }

    Import-GalleryModule 'Microsoft.WinGet.Client'
    Repair-WinGetPackageManager -AllUsers -Latest -Force | Out-Null
    $exe = Find-Winget
    if (Test-WingetUsable $exe) { return $exe }
    throw 'Could not install winget (App Installer). Update "App Installer" from the Microsoft Store and run Start-Setup.cmd again.'
}

function Test-AppInstalled($Detect) {
    if (-not $Detect) { return $false }
    if ($Detect.Service -and (Get-Service -Name $Detect.Service -ErrorAction SilentlyContinue)) { return $true }
    if ($Detect.Path -and (Test-Path ([Environment]::ExpandEnvironmentVariables($Detect.Path)))) { return $true }
    if ($Detect.DisplayName) {
        $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $hit = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $Detect.DisplayName }
        if ($hit) { return $true }
    }
    return $false
}

#endregion

#region Stages ------------------------------------------------------------

function Invoke-WindowsUpdateStage($State, $Config) {
    if ($State.SkipWindowsUpdate) { Add-Result $State 'Windows Update' 'Skipped'; return }

    Write-Log 'Windows Update' 'Step'
    Import-GalleryModule 'PSWindowsUpdate'
    try { Add-WUServiceManager -MicrosoftUpdate -Confirm:$false | Out-Null } catch { }   # also offers Office/other Microsoft product updates

    $filter = @{ MicrosoftUpdate = $true }
    $notCategory = @($Config.ExcludeCategories)
    if (-not $Config.IncludeDrivers) { $notCategory += 'Drivers' }
    if ($notCategory) { $filter.NotCategory = $notCategory }
    if ($Config.ExcludeTitle) { $filter.NotTitle = $Config.ExcludeTitle }

    while ($true) {
        if ($State.UpdateRound -ge $Config.MaxUpdateRounds) {
            Write-Log "Reached $($Config.MaxUpdateRounds) update rounds - moving on. Check Windows Update manually afterwards." 'Warn'
            Add-Result $State 'Windows Update' "Stopped after $($State.UpdateRound) rounds - check manually"
            return
        }
        $State.UpdateRound++
        Save-State $State

        Write-Log "Round $($State.UpdateRound): searching for updates (this can take a few minutes)..."
        $found = @(Get-WindowsUpdate @filter)
        if ($found.Count -eq 0) {
            if (Get-WURebootStatus -Silent) { Restart-AndResume $State 'finishing Windows Update' }
            Write-Log 'Windows is up to date.' 'Ok'
            Add-Result $State 'Windows Update' "Up to date ($($State.UpdateRound) rounds)"
            return
        }

        $found | ForEach-Object { Write-Log "$($_.KB) $($_.Title)" }
        Write-Log "Installing $($found.Count) update(s)..."
        Install-WindowsUpdate @filter -AcceptAll -IgnoreReboot | Out-Null

        if (Get-WURebootStatus -Silent) { Restart-AndResume $State 'Windows Update needs a restart' }
    }
}

function Invoke-StoreUpdateStage($State, $Config) {
    Write-Log 'Microsoft Store and app updates' 'Step'
    try {
        Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' |
            Invoke-CimMethod -MethodName UpdateScanMethod | Out-Null
        Write-Log 'Microsoft Store update scan started (Store apps update in the background).' 'Ok'
    } catch {
        Write-Log "Couldn't trigger the Store update scan: $($_.Exception.Message)" 'Warn'
    }

    $winget = Get-Winget
    Invoke-Native $winget @('source', 'update', '--disable-interactivity') | Out-Null
    $flags = @('--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')

    $ids = Get-UpgradablePackages
    if ($null -eq $ids) {
        Write-Log 'Upgrading everything winget can see...'
        $code = Invoke-Native $winget (@('upgrade', '--all', '--include-unknown') + $flags)
        if ($code -in $WingetOk) { Add-Result $State 'Store / app updates' 'Done' }
        else { Add-Result $State 'Store / app updates' "Partial (winget code $code)" }
        return
    }

    # One package at a time so a single failure doesn't abort the rest, and App Installer
    # last because upgrading it replaces winget.exe while it's running.
    $ids = @($ids | Where-Object { $id = $_; -not (@($Config.UpgradeExclude) | Where-Object { $_ -and $id -like $_ }) })
    $ids = @($ids | Where-Object { $_ -ne 'Microsoft.AppInstaller' }) + @($ids | Where-Object { $_ -eq 'Microsoft.AppInstaller' })
    Write-Log "$($ids.Count) app update(s) available."
    $failed = @()
    foreach ($id in $ids) {
        Write-Log "Updating $id..."
        $code = Invoke-Native $winget (@('upgrade', '--id', $id, '--exact') + $flags)
        if ($code -notin $WingetOk) { Write-Log "$id did not update (winget code $code)." 'Warn'; $failed += $id }
    }
    if ($failed) { Add-Result $State 'Store / app updates' "Partial - not updated: $($failed -join ', ')" }
    else { Add-Result $State 'Store / app updates' "Done ($($ids.Count) updated)" }
}

function Get-UpgradablePackages {
    # Returns winget IDs with an update, or $null if the list can't be read.
    try {
        Import-GalleryModule 'Microsoft.WinGet.Client'
        return , @(Get-WinGetPackage -Source winget | Where-Object { $_.IsUpdateAvailable } | ForEach-Object { $_.Id })
    } catch {
        Write-Log "Couldn't list app updates individually ($($_.Exception.Message)) - using 'winget upgrade --all'." 'Warn'
        return $null
    }
}

function Install-WingetApp($App) {
    $winget = Get-Winget
    & $winget list --id $App.WingetId --exact --accept-source-agreements --disable-interactivity *> $null
    if ($LASTEXITCODE -eq 0) { return 'Already installed' }

    $base = @('install', '--id', $App.WingetId, '--exact', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    $code = if ($App.Scope) { Invoke-Native $winget ($base + @('--scope', $App.Scope)) } else { Invoke-Native $winget $base }
    if ($code -notin $WingetOk -and $App.Scope) {
        Write-Log "Retrying without --scope $($App.Scope)..."
        $code = Invoke-Native $winget $base
    }
    if ($code -in $WingetOk) { return 'Installed' }
    throw "winget exit code $code"
}

function Resolve-KitPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $KitDir $Path }
}

function Get-SkipReason($App) {
    if ((Test-NotConfigured $App.Installer) -or (Test-NotConfigured $App.Arguments)) { return 'not configured in config.psd1 (CHANGE-ME)' }
    if ($App.Installer -and -not $App.DownloadUrl -and -not (Test-Path (Resolve-KitPath $App.Installer))) { return "installer not found: $(Resolve-KitPath $App.Installer)" }
}

function Install-FileApp($App) {
    if ($App.DownloadUrl) {
        $dir = Join-Path $WorkDir 'downloads'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir ([IO.Path]::GetFileName(([uri]$App.DownloadUrl).AbsolutePath))
        Write-Log "Downloading $($App.DownloadUrl)"
        Invoke-WebRequest -Uri $App.DownloadUrl -OutFile $path -UseBasicParsing
    } else {
        $path = Resolve-KitPath $App.Installer
    }
    if ($App.Signer) {
        $sig = Get-AuthenticodeSignature -FilePath $path
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike "*O=$($App.Signer),*") {
            throw "digital signature check failed ($($sig.Status), $($sig.SignerCertificate.Subject))"
        }
        Write-Log "Signature OK: $($App.Signer)"
    }

    if ($path -like '*.msi') {
        $file = 'msiexec.exe'
        $arguments = "/i `"$path`" /qn /norestart $($App.Arguments)".Trim()
    } else {
        $file = $path
        $arguments = "$($App.Arguments)".Trim()
    }
    $arguments = $arguments.Replace('{KIT}', $KitDir)
    Write-Log "Running $([IO.Path]::GetFileName($path)) $($arguments -replace 'CID=\S+', 'CID=***')"
    $start = @{ FilePath = $file; Wait = $true; PassThru = $true }
    if ($arguments) { $start.ArgumentList = $arguments }
    $p = Start-Process @start
    if ($p.ExitCode -in $InstallerOk) { return 'Installed' }
    throw "installer exit code $($p.ExitCode)"
}

function Invoke-AppsStage($State, $Config) {
    Write-Log 'Installing company programs' 'Step'
    foreach ($app in $Config.Apps) {
        Write-Log $app.Name 'Step'
        try {
            $skip = Get-SkipReason $app
            if (Test-AppInstalled $app.Detect) {
                $result = 'Already installed'
            } elseif ($skip) {
                $result = "Skipped - $skip"
            } elseif ($app.WingetId) {
                $result = Install-WingetApp $app
            } else {
                $result = Install-FileApp $app
                if ($app.Detect -and -not (Test-AppInstalled $app.Detect)) { throw 'installer finished but the program was not found afterwards' }
            }
            Write-Log "$($app.Name): $result" $(if ($skip -and $result -like 'Skipped*') { 'Warn' } else { 'Ok' })
        } catch {
            $result = "FAILED - $($_.Exception.Message)"
            Write-Log "$($app.Name): $result" 'Error'
        }
        Add-Result $State $app.Name $result
    }
}

function Invoke-DomainJoinStage($State, $Config) {
    if ($State.SkipDomainJoin) { Add-Result $State 'Domain join' 'Skipped'; return }

    $domain = $State.DomainName
    Write-Log "Joining domain $domain" 'Step'
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain) {
        Write-Log "Already joined to $($cs.Domain)." 'Ok'
        Add-Result $State 'Domain join' "Already joined to $($cs.Domain)"
        return
    }

    $cred = $null
    if (Test-Path $CredFile) { try { $cred = Import-Clixml $CredFile } catch { } }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not $cred) { $cred = Get-Credential -Message "Account allowed to join PCs to $domain (DOMAIN\user)" }
        if (-not $cred) { break }
        $join = @{ DomainName = $domain; Credential = $cred; Force = $true }
        if ($Config.OUPath) { $join.OUPath = $Config.OUPath }
        if ($State.ComputerName -and $State.ComputerName -ne $env:COMPUTERNAME) { $join.NewName = $State.ComputerName }
        try {
            Add-Computer @join
            $name = if ($join.NewName) { $join.NewName } else { $env:COMPUTERNAME }
            Write-Log "Joined $domain as $name." 'Ok'
            Add-Result $State 'Domain join' "Joined $domain as $name"
            Remove-Item $CredFile -Force -ErrorAction SilentlyContinue
            return
        } catch {
            Write-Log "Domain join failed: $($_.Exception.Message)" 'Error'
            $cred = $null
        }
    }
    Remove-Item $CredFile -Force -ErrorAction SilentlyContinue
    Add-Result $State 'Domain join' 'FAILED - join manually (see setup.log)'
}

#endregion

#region Main --------------------------------------------------------------

if (-not (Test-IsAdmin)) {
    Write-Host 'Please run this as administrator (right-click Start-Setup.cmd > Run as administrator).' -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { Start-Transcript -Path (Join-Path $WorkDir 'transcript.log') -Append | Out-Null } catch { }
try { $Host.UI.RawUI.WindowTitle = 'New PC setup - do not close' } catch { }

try {
    $state = $null
    if (Test-Path $StateFile) { $state = Import-Clixml $StateFile }

    if (-not $Resume) {
        if ($state -and $state.Stage -ne 'Done') {
            $answer = if ($Unattended) { 'y' } else { Read-Host "A setup is already in progress (stage: $($state.Stage)). Continue it? [Y/n]" }
            if ($answer -match '^n') { $state = $null }
        } else {
            $state = $null
        }

        if (-not $state) {
            Write-Log 'New PC setup' 'Step'
            # Run from a local copy so the USB stick / share can go away during reboots.
            if ($PSScriptRoot -ne $KitDir) {
                Write-Log "Copying setup kit to $KitDir..."
                robocopy $PSScriptRoot $KitDir /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "Copying the kit failed (robocopy code $LASTEXITCODE)." }
                Get-ChildItem $KitDir -Recurse -File | Unblock-File
            }
            $state = New-State
            $config = Import-PowerShellDataFile (Join-Path $KitDir 'config.psd1')

            # Ask everything up front so the rest runs unattended.
            if ($config.AskForComputerName -and -not $Unattended) {
                do {
                    $name = (Read-Host "New computer name (Enter = keep '$env:COMPUTERNAME')").Trim()
                    $valid = (-not $name) -or ($name -match '^[A-Za-z0-9-]{1,15}$' -and $name -notmatch '^\d+$')
                    if (-not $valid) { Write-Log 'Use 1-15 letters, numbers or hyphens (not only numbers).' 'Warn' }
                } until ($valid)
                if ($name) { $state.ComputerName = $name.ToUpper() }
            }

            if (-not $state.SkipDomainJoin) {
                $state.DomainName = $config.DomainName
                if (-not $state.DomainName -or (Test-NotConfigured $state.DomainName)) {
                    $state.DomainName = (Read-Host 'Domain to join (e.g. corp.company.com, Enter = skip domain join)').Trim()
                }
                if ($state.DomainName) {
                    $cred = Get-Credential -Message "Account allowed to join PCs to $($state.DomainName) (DOMAIN\user)"
                    # Encrypted with DPAPI - only this user on this PC can read it. Deleted after the join.
                    if ($cred) { $cred | Export-Clixml -Path $CredFile -Force }
                } else {
                    $state.SkipDomainJoin = $true
                }
            }

            foreach ($app in $config.Apps) {
                if ((Test-NotConfigured $app.Installer) -or (Test-NotConfigured $app.Arguments)) {
                    Write-Log "$($app.Name) is not configured in config.psd1 yet - it will be skipped." 'Warn'
                }
            }

            Save-State $state
            Register-ResumeTask
            Write-Log 'All questions answered. You can leave the PC now - it may restart several times.' 'Ok'
            Write-Log "After each restart, log back in as '$env:USERNAME' and setup continues by itself." 'Ok'
        }
    } elseif (-not $state) {
        Unregister-ResumeTask
        exit 0
    }

    if ($state.Unattended) { $Unattended = $true }
    if ($Resume) { Write-Log "Resuming setup at stage: $($state.Stage)" 'Step'; Start-Sleep -Seconds 10 }
    $config = Import-PowerShellDataFile (Join-Path $KitDir 'config.psd1')
    Wait-ForInternet

    while ($state.Stage -ne 'Done') {
        switch ($state.Stage) {
            'WindowsUpdate' { Invoke-WindowsUpdateStage $state $config }
            'StoreUpdates'  { Invoke-StoreUpdateStage   $state $config }
            'Apps'          { Invoke-AppsStage          $state $config }
            'DomainJoin'    { Invoke-DomainJoinStage    $state $config }
        }
        Set-NextStage $state
    }

    Unregister-ResumeTask
    Remove-Item $CredFile -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Log 'Setup finished - summary' 'Step'
    foreach ($r in $state.Results) {
        $level = if ($r.Result -like 'FAILED*' -or $r.Result -like 'Partial*' -or $r.Result -like 'Stopped*') { 'Warn' } else { 'Ok' }
        Write-Log ('{0,-28} {1}' -f $r.Item, $r.Result) $level
    }
    Write-Log "Full log: $LogFile"
    Write-Host ''
    if ($Unattended) {
        if ($state.Results | Where-Object { $_.Result -like 'FAILED*' }) { exit 2 }
        exit 0
    }
    $answer = Read-Host 'Restart now to finish (needed for the domain join)? [Y/n]'
    if ($answer -notmatch '^n') {
        try { Stop-Transcript | Out-Null } catch { }
        Restart-Computer -Force
    }
}
catch {
    Write-Log "Setup stopped: $($_.Exception.Message)" 'Error'
    Write-Log "Fix the problem and run Start-Setup.cmd again - it continues where it left off. Log: $LogFile" 'Error'
    if (-not $Unattended) { Read-Host 'Press Enter to close' }
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}

#endregion
