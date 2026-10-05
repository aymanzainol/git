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

.PARAMETER FirstLogonCleanup
    Used by a SYSTEM task at the first sign-in after setup. You don't need to pass it.

.PARAMETER Unattended
    No questions and no restart prompt at the end (keeps the current PC name).
    For testing in Windows Sandbox or CI. Exit code 2 = something failed.
#>
[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipDomainJoin,
    [switch]$Unattended,
    [switch]$FirstLogonCleanup
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'Continue'

$WorkDir   = Join-Path $env:ProgramData 'PCSetup'
$KitDir    = Join-Path $WorkDir 'kit'
$StateFile = Join-Path $WorkDir 'state.xml'
$CredFile  = Join-Path $WorkDir 'domain-cred.xml'
$UserCredFile = Join-Path $WorkDir 'user-cred.xml'
$FirstLogonDir = Join-Path $env:ProgramData 'PCSetup-FirstLogon'
$FirstLogonTaskName = 'PCSetup-FirstLogon'
$CleanupTaskName = 'PCSetup-FirstLogonCleanup'
$LogFile   = Join-Path $WorkDir 'setup.log'
$TaskName  = 'PCSetup-Resume'
$Stages    = @('Regional', 'WindowsUpdate', 'StoreUpdates', 'Apps', 'DomainJoin', 'UserSetup', 'Done')

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
        Stage             = 'Regional'
        UpdateRound       = 0
        ComputerName      = $null
        UserName          = $null
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
    $ProgressPreference = 'SilentlyContinue'
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

function Wait-AppInstalled($App) {
    $deadline = (Get-Date).AddMinutes([double]$App.WaitMinutes)
    while (-not (Test-AppInstalled $App.Detect)) {
        if ((Get-Date) -ge $deadline) { return $false }
        Write-Progress -Id 3 -Activity $App.Name -Status 'Waiting for the installer to finish...'
        Start-Sleep -Seconds 10
    }
    Write-Progress -Id 3 -Activity $App.Name -Completed
    return $true
}

#endregion

#region Stages ------------------------------------------------------------

# Windows Update is driven through the built-in Windows Update Agent COM API: no
# extra module, each update listed on its own, and a live progress bar.
$WuCallbackSource = @'
using System;
using System.Runtime.InteropServices;
namespace PCSetup {
    [ComImport, Guid("8C3F1CDD-6173-4591-AEBD-A56A53CA77C1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDownloadProgressChangedCallback { void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job, [MarshalAs(UnmanagedType.IDispatch)] object args); }
    [ComImport, Guid("77254866-9F5B-4C8E-B9E2-C77A8530D64B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDownloadCompletedCallback { void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job, [MarshalAs(UnmanagedType.IDispatch)] object args); }
    [ComImport, Guid("E01402D5-F8DA-43BA-A012-38894BD048F1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IInstallationProgressChangedCallback { void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job, [MarshalAs(UnmanagedType.IDispatch)] object args); }
    [ComImport, Guid("45F4F6F3-D602-4F98-9A8A-3EFA152AD2D3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IInstallationCompletedCallback { void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job, [MarshalAs(UnmanagedType.IDispatch)] object args); }

    // No-op callbacks: the script polls the job for progress instead.
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public class WuCallback : IDownloadProgressChangedCallback, IDownloadCompletedCallback,
                              IInstallationProgressChangedCallback, IInstallationCompletedCallback {
        void IDownloadProgressChangedCallback.Invoke(object job, object args) { }
        void IDownloadCompletedCallback.Invoke(object job, object args) { }
        void IInstallationProgressChangedCallback.Invoke(object job, object args) { }
        void IInstallationCompletedCallback.Invoke(object job, object args) { }
    }
}
'@

function Get-PendingReboot {
    $reasons = @()
    try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { $reasons += 'Windows Update' } } catch { }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Windows servicing' }
    @($reasons | Select-Object -Unique)
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) } elseif ($Bytes -ge 1MB) { '{0:N0} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f ($Bytes / 1KB) }
}

function Get-WuCallback {
    if ($null -eq $script:WuCallback) {
        try {
            if (-not ('PCSetup.WuCallback' -as [type])) { Add-Type -TypeDefinition $WuCallbackSource -Language CSharp }
            $script:WuCallback = New-Object PCSetup.WuCallback
        } catch {
            Write-Log "Live progress not available ($($_.Exception.Message)) - updates still install, without a percentage." 'Warn'
            $script:WuAsyncWarned = $true
            $script:WuCallback = $false
        }
    }
    $script:WuCallback
}

function Invoke-WuStep {
    # Downloads or installs one update with a progress bar. Returns the WUA result object.
    param($Session, $Update, [ValidateSet('Download', 'Install')][string]$Kind, [int]$Index, [int]$Total)

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    [void]$coll.Add($Update)
    if ($Kind -eq 'Download') {
        $op = $Session.CreateUpdateDownloader()
    } else {
        $op = $Session.CreateUpdateInstaller()
        try { $op.ForceQuiet = $true } catch { }
    }
    $op.Updates = $coll

    $verb = if ($Kind -eq 'Download') { 'Downloading' } else { 'Installing' }
    $activity = "Windows Update - $verb $Index of $Total"
    Write-Progress -Id 1 -Activity 'Windows Update' -Status "$verb $Index of $Total" -PercentComplete ((($Index - 1) / $Total) * 100)
    $watch = [Diagnostics.Stopwatch]::StartNew()

    $job = $null
    $cb = Get-WuCallback
    if ($cb) {
        try {
            $job = if ($Kind -eq 'Download') { $op.BeginDownload($cb, $cb, $null) } else { $op.BeginInstall($cb, $cb, $null) }
        } catch {
            $job = $null
            if (-not $script:WuAsyncWarned) { Write-Log "Live progress not available ($($_.Exception.Message)) - updates still install, without a percentage." 'Warn' }
            $script:WuAsyncWarned = $true
        }
    }

    if ($job) {
        while (-not $job.IsCompleted) {
            $pct = 0
            try { $pct = [int]$job.GetProgress().PercentComplete } catch { }
            Write-Progress -Id 2 -ParentId 1 -Activity $activity -Status ("{0}%   {1:hh\:mm\:ss} elapsed" -f $pct, $watch.Elapsed) -CurrentOperation $Update.Title -PercentComplete $pct
            Start-Sleep -Milliseconds 500
        }
        $result = if ($Kind -eq 'Download') { $op.EndDownload($job) } else { $op.EndInstall($job) }
    } else {
        # No live percentage available - run it synchronously.
        Write-Progress -Id 2 -ParentId 1 -Activity $activity -Status 'working...' -CurrentOperation $Update.Title
        $result = if ($Kind -eq 'Download') { $op.Download() } else { $op.Install() }
    }
    Write-Progress -Id 2 -Activity $activity -Completed
    $result
}

function Get-WuResultText($Result) {
    $codes = @{ 0 = 'not started'; 1 = 'in progress'; 2 = 'OK'; 3 = 'OK with errors'; 4 = 'failed'; 5 = 'aborted' }
    $text = $codes[[int]$Result.ResultCode]
    $hr = 0
    try { $hr = $Result.GetUpdateResult(0).HResult } catch { try { $hr = $Result.HResult } catch { } }
    if ($hr) { $text += ' (0x{0:X8})' -f $hr }
    $text
}

function Add-PreloadLayout([string]$Key, [string[]]$Layouts) {
    # Adds keyboard layouts to a Keyboard Layout\Preload key (1 = default, 2, 3... = others).
    $existing = @()
    $props = Get-ItemProperty -Path "Registry::$Key" -ErrorAction SilentlyContinue
    if ($props) { $existing = @($props.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' } | Sort-Object { [int]$_.Name } | ForEach-Object { $_.Value }) }
    foreach ($layout in $Layouts) { if ($existing -notcontains $layout) { $existing += $layout } }
    for ($i = 0; $i -lt $existing.Count; $i++) {
        reg.exe add $Key /v ($i + 1) /t REG_SZ /d $existing[$i] /f | Out-Null
    }
}

function Invoke-RegionalStage($State, $Config) {
    Write-Log 'Time zone and keyboard' 'Step'
    try {
        if ($Config.TimeZone) {
            # Stop Windows changing it back automatically.
            reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Services\tzautoupdate' /v Start /t REG_DWORD /d 4 /f | Out-Null
            Set-TimeZone -Id $Config.TimeZone
            Write-Log "Time zone: $((Get-TimeZone).DisplayName)" 'Ok'
            # "Set time automatically" on: Windows Time service running and synced now.
            Set-Service -Name W32Time -StartupType Automatic
            Start-Service -Name W32Time -ErrorAction SilentlyContinue
            Start-Process w32tm.exe -ArgumentList '/resync /nowait' -WindowStyle Hidden -ErrorAction SilentlyContinue
        }

        $langs = @($Config.Keyboards)
        if ($langs) {
            # This (setup) account
            $list = Get-WinUserLanguageList
            foreach ($tag in $langs) { if (-not ($list | Where-Object { $_.LanguageTag -eq $tag })) { $list.Add($tag) } }
            Set-WinUserLanguageList -LanguageList $list -Force -WarningAction SilentlyContinue

            # Everyone who signs in later (and the sign-in screen)
            $copied = $false
            if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
                try { Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true; $copied = $true } catch { }
            }
            $layouts = @($langs | ForEach-Object { $KeyboardLayouts[$_] } | Where-Object { $_ })
            Add-PreloadLayout 'HKU\.DEFAULT\Keyboard Layout\Preload' $layouts
            $hive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
            reg.exe load 'HKU\PCSetupDefault' $hive | Out-Null
            if (-not $LASTEXITCODE) {
                try { Add-PreloadLayout 'HKU\PCSetupDefault\Keyboard Layout\Preload' $layouts }
                finally { [GC]::Collect(); reg.exe unload 'HKU\PCSetupDefault' | Out-Null }
            }
            Write-Log "Keyboards: $((Get-WinUserLanguageList | ForEach-Object { $_.Autonym }) -join ', ') (also for new users$(if ($copied) { ' and the sign-in screen' }))" 'Ok'
        }
        Add-Result $State 'Time zone / keyboard' "$((Get-TimeZone).Id); keyboards $($langs -join ', ')"
    } catch {
        Write-Log "Time zone / keyboard: $($_.Exception.Message)" 'Error'
        Add-Result $State 'Time zone / keyboard' "FAILED - $($_.Exception.Message)"
    }
}

# Language tag -> keyboard layout ID for the Preload list of new profiles.
$KeyboardLayouts = @{ 'en-US' = '00000409'; 'ar-SA' = '00000401'; 'en-GB' = '00000809'; 'fr-FR' = '0000040c' }

function Invoke-WindowsUpdateStage($State, $Config) {
    if ($State.SkipWindowsUpdate) { Add-Result $State 'Windows Update' 'Skipped'; return }
    Write-Log 'Windows Update' 'Step'

    # Windows often installs updates on its own during first sign-in. Finish those first.
    $pending = Get-PendingReboot
    if ($pending) {
        $State.PendingRestarts = [int]$State.PendingRestarts + 1
        if ($State.PendingRestarts -le 2) { Restart-AndResume $State "a restart is already pending ($($pending -join ', '))" }
        Write-Log "Windows still reports a pending restart ($($pending -join ', ')) after restarting - carrying on anyway." 'Warn'
    }
    $State.PendingRestarts = 0
    Save-State $State

    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'PC-Setup'
    try {
        # "Receive updates for other Microsoft products" (Office, .NET, etc.)
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        $mu = '7971f918-a847-4430-9279-4a52d1efe18d'
        if (-not ($sm.Services | Where-Object { $_.ServiceID -eq $mu })) { [void]$sm.AddService2($mu, 7, '') }
    } catch {
        Write-Log "Couldn't turn on Microsoft Update for other products: $($_.Exception.Message)" 'Warn'
    }
    $searcher = $session.CreateUpdateSearcher()

    while ($true) {
        if ($State.UpdateRound -ge $Config.MaxUpdateRounds) {
            Write-Log "Reached $($Config.MaxUpdateRounds) update rounds - moving on. Check Windows Update manually afterwards." 'Warn'
            Add-Result $State 'Windows Update' "Stopped after $($State.UpdateRound) rounds - check manually"
            return
        }
        $State.UpdateRound++
        Save-State $State

        Write-Log "Round $($State.UpdateRound): searching for updates (this can take a few minutes)..."
        Write-Progress -Id 1 -Activity 'Windows Update' -Status "Round $($State.UpdateRound): searching for updates..."
        $search = $searcher.Search('IsInstalled=0 and IsHidden=0')
        Write-Progress -Id 1 -Activity 'Windows Update' -Completed

        $todo = @()
        foreach ($u in @($search.Updates)) {
            $cats = @($u.Categories | ForEach-Object { $_.Name })
            $skip = $null
            if ($u.Type -eq 2 -and -not $Config.IncludeDrivers) { $skip = 'drivers turned off' }
            elseif ($hit = $cats | Where-Object { $_ -in @($Config.ExcludeCategories) } | Select-Object -First 1) { $skip = "category '$hit' excluded" }
            elseif ($Config.ExcludeTitle -and $u.Title -match $Config.ExcludeTitle) { $skip = "title matches '$($Config.ExcludeTitle)'" }

            $size = Format-Size $u.MaxDownloadSize
            if ($skip) {
                Write-Log "[skipped]    $($u.Title) - $skip" 'Warn'
            } else {
                $tag = if ($u.IsDownloaded) { '[downloaded]' } else { '[download]  ' }
                Write-Log "$tag $($u.Title)  ($size)"
                if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
                $todo += $u
            }
        }

        if ($todo.Count -eq 0) {
            $pending = Get-PendingReboot
            if ($pending) { Restart-AndResume $State "finishing Windows Update ($($pending -join ', '))" }
            Write-Log 'Windows is up to date.' 'Ok'
            Add-Result $State 'Windows Update' "Up to date ($($State.UpdateRound) rounds)"
            return
        }

        $installed = 0
        $failed = @()
        for ($i = 0; $i -lt $todo.Count; $i++) {
            $u = $todo[$i]
            if (-not $u.IsDownloaded) {
                $r = Invoke-WuStep -Session $session -Update $u -Kind Download -Index ($i + 1) -Total $todo.Count
                if ([int]$r.ResultCode -notin 2, 3) {
                    Write-Log "Download failed: $($u.Title) - $(Get-WuResultText $r)" 'Error'
                    $failed += $u.Title
                    continue
                }
            }
            $r = Invoke-WuStep -Session $session -Update $u -Kind Install -Index ($i + 1) -Total $todo.Count
            if ([int]$r.ResultCode -in 2, 3) {
                $installed++
                Write-Log "Installed: $($u.Title)$(if ($r.RebootRequired) { ' (restart needed)' })" 'Ok'
            } else {
                Write-Log "Install failed: $($u.Title) - $(Get-WuResultText $r)" 'Error'
                $failed += $u.Title
            }
        }
        Write-Progress -Id 1 -Activity 'Windows Update' -Completed
        Write-Log "Round $($State.UpdateRound): $installed installed, $($failed.Count) failed."

        $pending = Get-PendingReboot
        if ($pending) { Restart-AndResume $State 'Windows Update needs a restart' }
        if ($installed -eq 0) {
            # Nothing worked and no restart would help - don't loop on the same failures.
            Write-Log 'Updates keep failing - moving on. Retry them from Settings > Windows Update afterwards.' 'Warn'
            Add-Result $State 'Windows Update' "FAILED - $($failed -join '; ')"
            return
        }
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
    # Relative paths are inside the kit. Wildcards pick the newest matching .exe/.msi (or any
    # file for non-installer patterns such as CID*), so a new file name needs no config change.
    $full = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $KitDir $Path }
    if ($full -notmatch '[*?]') { return $full }
    $files = @(Get-ChildItem -Path $full -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.txt' })
    if ($Path -match '\\\*(\.\*)?$') { $files = @($files | Where-Object { $_.Extension -in '.exe', '.msi' }) }
    $hit = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { $hit.FullName }
}

function Get-CrowdStrikeCid($App) {
    # Reads the CID (32 hex characters + "-" + 2-character checksum) from the CID text file.
    $file = Resolve-KitPath $App.CidFile
    if (-not $file -or -not (Test-Path $file)) { return $null }
    $m = [regex]::Match((Get-Content -Path $file -Raw), '[0-9A-Fa-f]{32}-[0-9A-Fa-f]{2}')
    if ($m.Success) { $m.Value.ToUpper() }
}

function Get-SkipReason($App) {
    if ((Test-NotConfigured $App.Installer) -or (Test-NotConfigured $App.Arguments)) { return 'not configured in config.psd1 (CHANGE-ME)' }
    if ($App.Installer -and -not $App.DownloadUrl) {
        $path = Resolve-KitPath $App.Installer
        if (-not $path -or -not (Test-Path $path)) { return "no installer found in $(Split-Path (Join-Path $KitDir $App.Installer))" }
    }
    if ("$($App.Arguments)" -match '\{CID\}' -and -not (Get-CrowdStrikeCid $App)) { return "no CID found in $($App.CidFile)" }
}

function Get-InstallerKind([string]$Path) {
    # Recognises common installer builders from the file's version info and contents.
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    $text = "$($info.Comments) $($info.FileDescription) $($info.ProductName) $($info.InternalName) $($info.LegalTrademarks)"
    $fs = [IO.File]::OpenRead($Path)
    try {
        $reader = New-Object IO.BinaryReader($fs)
        $buf = $reader.ReadBytes([int][Math]::Min($fs.Length, 16MB))
    } finally { $fs.Dispose() }
    $text += [Text.Encoding]::ASCII.GetString($buf)
    $text += [Text.Encoding]::Unicode.GetString($buf)
    if ($buf.Length -gt 1) { $text += [Text.Encoding]::Unicode.GetString($buf, 1, $buf.Length - 1) }

    if ($text -match '\.wixburn')                      { return 'WiX' }
    if ($text -match 'Inno Setup')                     { return 'Inno Setup' }
    if ($text -match 'Nullsoft|NullsoftInst')          { return 'NSIS' }
    if ($text -match 'InstallShield')                  { return 'InstallShield' }
    if ($text -match 'Advanced Installer')             { return 'Advanced Installer' }
    if ($text -match 'Squirrel')                       { return 'Squirrel' }
    return $null
}

$SilentSwitches = @{
    'WiX'                = '/quiet /norestart'
    'Inno Setup'         = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
    'NSIS'               = '/S'
    'InstallShield'      = '/s /v"/qn REBOOT=ReallySuppress"'
    'Advanced Installer' = '/exenoui /qn /norestart'
    'Squirrel'           = '--silent'
}

function Get-ProcessTree([int]$RootId) {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId)
    $ids = @($RootId)
    for ($i = 0; $i -lt $ids.Count; $i++) { $ids += @($all | Where-Object { $_.ParentProcessId -eq $ids[$i] -and $_.ProcessId -notin $ids } | ForEach-Object { [int]$_.ProcessId }) }
    $ids
}

function Stop-InstallerTree([Diagnostics.Process]$Process) {
    foreach ($id in @(Get-ProcessTree $Process.Id | Sort-Object -Descending)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}

$ClickButtons = '^(Next|I Agree|I Accept|Accept|Install|Finish|Close|OK)\b'

# Runs in a background runspace so a hung UI Automation call can never freeze setup.
$ClickWatcher = {
    param($ProcessId, $ButtonPattern, $Check, $Sync)
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    function Get-Tree([int]$RootId) {
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId)
        $ids = @($RootId)
        for ($i = 0; $i -lt $ids.Count; $i++) { $ids += @($all | Where-Object { $_.ParentProcessId -eq $ids[$i] -and $_.ProcessId -notin $ids } | ForEach-Object { [int]$_.ProcessId }) }
        $ids
    }
    $A = [Windows.Automation.AutomationElement]
    $buttonCond = New-Object Windows.Automation.PropertyCondition($A::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
    $checkCond  = New-Object Windows.Automation.PropertyCondition($A::ControlTypeProperty, [Windows.Automation.ControlType]::CheckBox)
    while (-not $Sync.Stop) {
        Start-Sleep -Milliseconds 1500
        try {
            $ids = Get-Tree $ProcessId
            $windows = @($A::RootElement.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.ProcessId -in $ids })
            $Sync.Polls++
            if ($windows) { $Sync.SawWindow = $true }
            foreach ($w in $windows) {
                foreach ($cb in $w.FindAll([Windows.Automation.TreeScope]::Descendants, $checkCond)) {
                    if ($Check -and ($Check | Where-Object { $cb.Current.Name -like $_ })) {
                        $toggle = $cb.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
                        if ($toggle.Current.ToggleState -eq 'Off') { $toggle.Toggle(); $Sync.Messages.Enqueue("ticked '$($cb.Current.Name)'") }
                    }
                }
                $button = $w.FindAll([Windows.Automation.TreeScope]::Descendants, $buttonCond) |
                    Where-Object { $_.Current.IsEnabled -and ($_.Current.Name -replace '&', '') -match $ButtonPattern -and
                                   $_.Current.AutomationId -notin 'Close', 'Minimize', 'Maximize', 'Restore' } |   # title-bar buttons
                    Select-Object -First 1
                if ($button) {
                    $name = $button.Current.Name -replace '&', ''
                    $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                    $Sync.Messages.Enqueue("clicked '$name'")
                    $Sync.LastClick = Get-Date
                    Start-Sleep -Seconds 2
                    break
                }
            }
        } catch { }   # windows come and go while the wizard moves on
    }
}

function Invoke-ClickThrough([Diagnostics.Process]$Process, [string]$AppName, [string[]]$Check, [int]$TimeoutMinutes = 45) {
    # Presses Next / Install / Finish in the installer's own windows (keeping every default) until it exits.
    # Only windows of the installer process or its children are touched; never Cancel, Back or the title-bar X.
    $sync = [hashtable]::Synchronized(@{ Stop = $false; SawWindow = $false; Polls = 0; LastClick = Get-Date
                                         Messages = New-Object System.Collections.Concurrent.ConcurrentQueue[string] })
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($ClickWatcher).AddArgument($Process.Id).AddArgument($ClickButtons).AddArgument($Check).AddArgument($sync)
    $handle = $ps.BeginInvoke()
    $started = Get-Date
    $warned = $false
    try {
        while (-not $Process.HasExited) {
            Start-Sleep -Seconds 1
            $msg = $null
            while ($sync.Messages.TryDequeue([ref]$msg)) { Write-Log "  $AppName installer: $msg" }
            $elapsed = ((Get-Date) - $started).TotalMinutes
            if (-not $warned -and -not $sync.SawWindow -and $elapsed -gt 2) {
                Write-Log "  $AppName installer: can't see its window to click it$(if (-not $sync.Polls) { ' (window search not answering)' }). If it's on screen, click through it yourself - setup carries on when it closes." 'Warn'
                $warned = $true
            }
            if ($sync.SawWindow -and ((Get-Date) - $sync.LastClick).TotalMinutes -gt 30) {
                Stop-InstallerTree $Process
                throw 'the installer waited 30 minutes on a step that couldn''t be clicked automatically'
            }
            if ($elapsed -gt $TimeoutMinutes) {
                Stop-InstallerTree $Process
                throw "the installer was still running after $TimeoutMinutes minutes - stopped it"
            }
        }
    } finally {
        $sync.Stop = $true
        $msg = $null
        while ($sync.Messages.TryDequeue([ref]$msg)) { Write-Log "  $AppName installer: $msg" }
        # Don't wait on a watcher that may be stuck inside UI Automation.
        if ($handle.AsyncWaitHandle.WaitOne(5000)) { $ps.Dispose() } else { [void]$ps.BeginStop($null, $null) }
    }
}

function Install-FileApp($App) {
    if ($App.DownloadUrl) {
        $dir = Join-Path $WorkDir 'downloads'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir ([IO.Path]::GetFileName(([uri]$App.DownloadUrl).AbsolutePath))
        Write-Log "Downloading $($App.DownloadUrl)"
        $ProgressPreference = 'SilentlyContinue'   # the PS 5.1 progress bar makes downloads crawl
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

    $appArgs = "$($App.Arguments)".Trim()
    $clickThrough = $false
    if ($appArgs -eq 'CLICKTHROUGH') {
        $appArgs = ''
        $clickThrough = $true
    } elseif ($appArgs -eq 'AUTO') {
        $clickThrough = $true   # also a safety net in case the silent switches are ignored
        if ($path -like '*.msi') {
            $appArgs = ''
        } else {
            $kind = Get-InstallerKind $path
            if ($kind) {
                $appArgs = $SilentSwitches[$kind]
                Write-Log "$([IO.Path]::GetFileName($path)) is a $kind installer - using $appArgs"
            } else {
                $appArgs = ''
                Write-Log "$([IO.Path]::GetFileName($path)) has no known silent switches - clicking through its setup wizard with the default answers."
            }
        }
    }
    if ($appArgs -match '\{CID\}') { $appArgs = $appArgs.Replace('{CID}', (Get-CrowdStrikeCid $App)) }

    if ($path -like '*.msi') {
        $file = 'msiexec.exe'
        $arguments = "/i `"$path`" /qn /norestart $appArgs".Trim()
    } else {
        $file = $path
        $arguments = $appArgs
    }
    $arguments = $arguments.Replace('{KIT}', $KitDir)
    Write-Log "Running $([IO.Path]::GetFileName($path)) $($arguments -replace 'CID=\S+', 'CID=***')"
    $start = @{ FilePath = $file; Wait = -not ($App.NoWait -or $clickThrough); PassThru = $true }
    if ($arguments) { $start.ArgumentList = $arguments }
    $p = Start-Process @start
    if ($App.NoWait) { return 'Installed' }   # finished when Detect finds it
    if ($clickThrough) {
        $null = $p.Handle   # keeps the exit code readable after the process ends
        $timeout = if ($App.TimeoutMinutes) { [int]$App.TimeoutMinutes } else { 45 }
        Invoke-ClickThrough $p $App.Name @($App.Check) $timeout
        $p.WaitForExit()
    }
    if ($p.ExitCode -in $InstallerOk) { return 'Installed' }
    throw "installer exit code $($p.ExitCode)"
}

function Invoke-Exe([string]$File, [string]$Arguments, [string]$StdIn) {
    # Runs a program with optional input piped in; returns its output.
    $p = New-Object Diagnostics.Process
    $p.StartInfo.FileName = $File
    $p.StartInfo.Arguments = $Arguments
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardInput = $true
    $p.StartInfo.RedirectStandardOutput = $true
    [void]$p.Start()
    if ($StdIn) { $p.StandardInput.WriteLine($StdIn) }
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; throw "$([IO.Path]::GetFileName($File)) $Arguments did not finish" }
    $out.Result.Trim()
}

function Set-AnyDesk($App) {
    # Sets the unattended-access password and returns ", ID <id>" for the summary.
    $exe = [Environment]::ExpandEnvironmentVariables($App.Detect.Path)
    if (Test-NotConfigured $App.AnyDeskPassword) {
        Write-Log 'AnyDesk unattended password is not set in config.psd1 (CHANGE-ME) - skipped.' 'Warn'
        $extra = ', no unattended password (not configured)'
    } else {
        # The service has to be running before it accepts a password.
        for ($i = 0; $i -lt 12 -and -not (Get-Service -Name AnyDesk -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running'); $i++) { Start-Sleep -Seconds 5 }
        try {
            Invoke-Exe $exe '--set-password' $App.AnyDeskPassword | Out-Null
            Write-Log 'AnyDesk unattended password set.' 'Ok'
            $extra = ', unattended password set'
        } catch {
            Write-Log "Couldn't set the AnyDesk password: $($_.Exception.Message)" 'Error'
            $extra = ', unattended password NOT set'
        }
    }
    $id = ''
    for ($i = 0; $i -lt 6 -and $id -notmatch '^\d+$'; $i++) {
        try { $id = Invoke-Exe $exe '--get-id' } catch { }
        if ($id -notmatch '^\d+$') { Start-Sleep -Seconds 5 }
    }
    if ($id -match '^\d+$') { Write-Log "AnyDesk ID: $id" 'Ok'; $extra += ", ID $id" }
    $extra
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
                if ($app.Detect -and -not (Wait-AppInstalled $app)) { throw 'installer finished but the program was not found afterwards' }
            }
            if ($app.AnyDeskPassword -and $result -notlike 'Skipped*') { $result += Set-AnyDesk $app }
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

#region First sign-in (domain user, Outlook, OneDrive) ---------------------

# Automatic sign-in keeps the password in an LSA secret (like Sysinternals Autologon),
# not in plain text in the registry.
$LsaSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace PCSetup {
    public static class Lsa {
        [StructLayout(LayoutKind.Sequential)]
        struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
        [StructLayout(LayoutKind.Sequential)]
        struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }

        [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr handle);
        [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr handle, ref LSA_UNICODE_STRING key, IntPtr data);
        [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr handle, ref LSA_UNICODE_STRING key, out IntPtr data);
        [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
        [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr buffer);
        [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);

        const uint POLICY_GET_PRIVATE_INFORMATION = 0x4;
        const uint POLICY_CREATE_SECRET = 0x20;
        const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;

        static LSA_UNICODE_STRING Str(string s) {
            var u = new LSA_UNICODE_STRING();
            u.Buffer = Marshal.StringToHGlobalUni(s);
            u.Length = (ushort)(s.Length * 2);
            u.MaximumLength = (ushort)(s.Length * 2 + 2);
            return u;
        }

        static IntPtr Open(uint access) {
            var attrs = new LSA_OBJECT_ATTRIBUTES();
            attrs.Length = Marshal.SizeOf(attrs);
            IntPtr handle;
            uint status = LsaOpenPolicy(IntPtr.Zero, ref attrs, access, out handle);
            if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
            return handle;
        }

        // value = null deletes the secret.
        public static void Store(string key, string value) {
            IntPtr handle = Open(POLICY_CREATE_SECRET);
            LSA_UNICODE_STRING k = Str(key);
            IntPtr valueBuffer = IntPtr.Zero, valuePtr = IntPtr.Zero;
            try {
                if (value != null) {
                    LSA_UNICODE_STRING v = Str(value);
                    valueBuffer = v.Buffer;
                    valuePtr = Marshal.AllocHGlobal(Marshal.SizeOf(v));
                    Marshal.StructureToPtr(v, valuePtr, false);
                }
                uint status = LsaStorePrivateData(handle, ref k, valuePtr);
                if (status != 0 && !(value == null && status == STATUS_OBJECT_NAME_NOT_FOUND))
                    throw new Win32Exception(LsaNtStatusToWinError(status));
            } finally {
                Marshal.FreeHGlobal(k.Buffer);
                if (valueBuffer != IntPtr.Zero) Marshal.FreeHGlobal(valueBuffer);
                if (valuePtr != IntPtr.Zero) Marshal.FreeHGlobal(valuePtr);
                LsaClose(handle);
            }
        }

        // True when the secret holds a non-empty value.
        public static bool Exists(string key) {
            IntPtr handle = Open(POLICY_GET_PRIVATE_INFORMATION);
            LSA_UNICODE_STRING k = Str(key);
            try {
                IntPtr data;
                uint status = LsaRetrievePrivateData(handle, ref k, out data);
                if (status != 0 || data == IntPtr.Zero) return false;
                // A deleted secret can linger as an empty value; that counts as no password.
                var value = (LSA_UNICODE_STRING)Marshal.PtrToStructure(data, typeof(LSA_UNICODE_STRING));
                LsaFreeMemory(data);
                return value.Length > 0;
            } finally {
                Marshal.FreeHGlobal(k.Buffer);
                LsaClose(handle);
            }
        }
    }
}
'@

$WinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Import-LsaType {
    if (-not ('PCSetup.Lsa' -as [type])) { Add-Type -TypeDefinition $LsaSource -Language CSharp }
}

function Test-DomainCredential([string]$Domain, [pscredential]$Credential) {
    # $true / $false, or $null when the domain can't be reached to check.
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
            [System.DirectoryServices.AccountManagement.ContextType]::Domain, $Domain)
        $user = $Credential.UserName -replace '^.*\\', ''
        return $ctx.ValidateCredentials($user, $Credential.GetNetworkCredential().Password)
    } catch {
        return $null
    }
}

function Get-NetbiosDomain([string]$Domain, [pscredential]$Credential) {
    try {
        $user = $Credential.UserName; $pw = $Credential.GetNetworkCredential().Password
        $rootDse = New-Object DirectoryServices.DirectoryEntry("LDAP://$Domain/RootDSE", $user, $pw)
        $configNc = $rootDse.Properties['configurationNamingContext'][0]
        $partitions = New-Object DirectoryServices.DirectoryEntry("LDAP://$Domain/CN=Partitions,$configNc", $user, $pw)
        $searcher = New-Object DirectoryServices.DirectorySearcher($partitions, "(&(objectClass=crossRef)(dnsRoot=$Domain)(nETBIOSName=*))")
        $name = $searcher.FindOne().Properties['netbiosname'][0]
        if ($name) { return [string]$name }
    } catch { }
    return $Domain
}

function Set-AutoLogon([pscredential]$Credential, [string]$Domain) {
    # Signs in once as this user on the next start; Winlogon turns it off after that one sign-in.
    Import-LsaType
    $user = $Credential.UserName
    if ($user -match '^(.+)\\(.+)$') { $dom = $Matches[1]; $user = $Matches[2] }
    elseif ($user -like '*@*') { $dom = '' }
    else { $dom = Get-NetbiosDomain $Domain $Credential }

    [PCSetup.Lsa]::Store('DefaultPassword', $Credential.GetNetworkCredential().Password)
    Remove-ItemProperty -Path $WinlogonKey -Name DefaultPassword -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $WinlogonKey -Name AutoAdminLogon -Value '1'
    Set-ItemProperty -Path $WinlogonKey -Name DefaultUserName -Value $user
    Set-ItemProperty -Path $WinlogonKey -Name DefaultDomainName -Value $dom
    New-ItemProperty -Path $WinlogonKey -Name AutoLogonCount -Value 1 -PropertyType DWord -Force | Out-Null
    $(if ($dom) { "$dom\$user" } else { $user })
}

function Clear-AutoLogon {
    Import-LsaType
    [PCSetup.Lsa]::Store('DefaultPassword', $null)
    Set-ItemProperty -Path $WinlogonKey -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty -Path $WinlogonKey -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
}

function Set-RegDword([string]$Key, [string]$Name, [int]$Value) {
    reg.exe add $Key /v $Name /t REG_DWORD /d $Value /f | Out-Null
    if ($LASTEXITCODE) { throw "Couldn't write $Key\$Name" }
}

function Set-DefaultUserSettings {
    # Written into the default profile, so every new user profile starts with them.
    $hive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    reg.exe load 'HKU\PCSetupDefault' $hive | Out-Null
    if ($LASTEXITCODE) { throw "Couldn't load the default user profile ($hive)" }
    try {
        $root = 'HKU\PCSetupDefault\Software'
        Set-RegDword "$root\Microsoft\Office\16.0\Outlook\AutoDiscover" 'ZeroConfigExchange' 1         # create the mail profile from the signed-in account
        Set-RegDword "$root\Microsoft\Office\16.0\Outlook\Options\General" 'HideNewOutlookToggle' 1    # no "Try the new Outlook" switch
        Set-RegDword "$root\Policies\Microsoft\Office\16.0\Outlook\Preferences" 'DoNewOutlookAutoMigration' 0
    } finally {
        [GC]::Collect()
        reg.exe unload 'HKU\PCSetupDefault' | Out-Null
    }
}

function Set-MachinePolicies($Config) {
    $od = 'HKLM\SOFTWARE\Policies\Microsoft\OneDrive'
    Set-RegDword $od 'SilentAccountConfig' 1      # sign in to OneDrive with the Windows account
    Set-RegDword $od 'FilesOnDemandEnabled' 1
    if ($Config.OneDriveTenantId -and -not (Test-NotConfigured $Config.OneDriveTenantId)) {
        reg.exe add $od /v KFMSilentOptIn /t REG_SZ /d $Config.OneDriveTenantId /f | Out-Null   # Desktop/Documents/Pictures into OneDrive
    }
    if ($Config.RemoveNewOutlookApp) {
        try {
            Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'Microsoft.OutlookForWindows' } |
                ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null }
            Get-AppxPackage -AllUsers -Name 'Microsoft.OutlookForWindows' | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Write-Log 'Removed the "new Outlook" app.'
        } catch {
            Write-Log "Couldn't remove the new Outlook app: $($_.Exception.Message)" 'Warn'
        }
    }
}

function Register-FirstLogonTasks($State) {
    New-Item -ItemType Directory -Path $FirstLogonDir -Force | Out-Null
    Copy-Item (Join-Path $KitDir 'FirstLogon.ps1') $FirstLogonDir -Force
    $script = Join-Path $FirstLogonDir 'FirstLogon.ps1'
    $userArg = if ($State.UserName) { " -OnlyUser `"$($State.UserName)`"" } else { '' }
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    # Runs as whoever signs in (non-admin): opens OneDrive and classic Outlook once per user.
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"$userArg"
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    Register-ScheduledTask -TaskName $FirstLogonTaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $principal -Settings $settings -Force | Out-Null

    # Runs as SYSTEM at the first sign-in: removes the saved password and the Office files copy.
    $setup     = Join-Path $KitDir 'Setup-NewPC.ps1'
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$setup`" -FirstLogonCleanup"
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $CleanupTaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $principal -Settings $settings -Force | Out-Null
}

function Invoke-UserSetupStage($State, $Config) {
    if ($State.SkipDomainJoin) { return }
    $joined = $State.Results | Where-Object { $_.Item -eq 'Domain join' -and $_.Result -notlike 'FAILED*' -and $_.Result -ne 'Skipped' }
    if (-not $joined) {
        Remove-Item $UserCredFile -Force -ErrorAction SilentlyContinue
        Add-Result $State 'First sign-in' 'Skipped - the PC is not on the domain'
        return
    }

    Write-Log 'Preparing the first sign-in (classic Outlook, OneDrive)' 'Step'
    try {
        Set-MachinePolicies $Config
        Set-DefaultUserSettings
        Register-FirstLogonTasks $State
        Add-Result $State 'Outlook / OneDrive' 'Open and sign in at the first sign-in'
    } catch {
        Write-Log "Outlook / OneDrive setup failed: $($_.Exception.Message)" 'Error'
        Add-Result $State 'Outlook / OneDrive' "FAILED - $($_.Exception.Message)"
    }

    if (Test-Path $UserCredFile) {
        try {
            $account = Set-AutoLogon (Import-Clixml $UserCredFile) $State.DomainName
            Write-Log "After the restart the PC signs in as $account (once)." 'Ok'
            Add-Result $State 'First sign-in' "Signs in automatically as $account after the restart"
        } catch {
            Write-Log "Couldn't set up automatic sign-in: $($_.Exception.Message)" 'Error'
            Add-Result $State 'First sign-in' "FAILED - $($_.Exception.Message)"
        } finally {
            Remove-Item $UserCredFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-FirstLogonCleanup {
    Clear-AutoLogon
    # Register the PC with Microsoft 365 (hybrid join) now rather than at Windows' next scheduled try,
    # so Outlook and OneDrive stop asking for the password sooner. Does nothing if the domain isn't set up for it.
    try {
        Start-ScheduledTask -TaskPath '\Microsoft\Windows\Workplace Join\' -TaskName 'Automatic-Device-Join'
        Write-Log 'Started the Microsoft 365 device registration (hybrid join).'
    } catch {
        Write-Log "Couldn't start the device registration task: $($_.Exception.Message)" 'Warn'
    }
    Unregister-ScheduledTask -TaskName $CleanupTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $KitDir 'installers'), (Join-Path $KitDir 'config.psd1') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log 'First sign-in done: automatic sign-in is off, the saved password, the installer copies and config.psd1 are removed.' 'Ok'
}

#endregion

#region Main --------------------------------------------------------------

if (-not (Test-IsAdmin)) {
    Write-Host 'Please run this as administrator (right-click Start-Setup.cmd > Run as administrator).' -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
# Only admins and SYSTEM may read the work folder (it briefly holds encrypted passwords).
icacls.exe $WorkDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($FirstLogonCleanup) {
    try { Invoke-FirstLogonCleanup } catch { Write-Log "First sign-in cleanup failed: $($_.Exception.Message)" 'Error'; exit 1 }
    exit 0
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# Keep the PC awake with the screen on (no sleep, no lock) while setup runs; ends with this window.
try {
    Add-Type -Namespace PCSetup -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);'
    [void][PCSetup.Power]::SetThreadExecutionState([uint32]'0x80000003')   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
} catch { }
try { Start-Transcript -Path (Join-Path $WorkDir 'transcript.log') -Append | Out-Null } catch { }
try { $Host.UI.RawUI.WindowTitle = 'New PC setup - do not close' } catch { }

try {
    $state = $null
    if (Test-Path $StateFile) { $state = Import-Clixml $StateFile }

    if (-not $Resume) {
        # Run from a local copy so the USB stick / share can go away during reboots.
        # Refreshed on every manual start, so a newer kit also takes over a run in progress.
        if ($PSScriptRoot -ne $KitDir) {
            Write-Log "Copying setup kit to $KitDir..."
            robocopy $PSScriptRoot $KitDir /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Copying the kit failed (robocopy code $LASTEXITCODE)." }
            Get-ChildItem $KitDir -Recurse -File | Unblock-File
        }

        if ($state -and $state.Stage -ne 'Done') {
            $answer = if ($Unattended) { 'y' } else { Read-Host "A setup is already in progress (stage: $($state.Stage)). Continue it? [Y/n]" }
            if ($answer -match '^n') { $state = $null }
        } else {
            $state = $null
        }

        if (-not $state) {
            Write-Log 'New PC setup' 'Step'
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
                    for ($try = 1; $try -le 3; $try++) {
                        $cred = Get-Credential -Message "Account allowed to join PCs to $($state.DomainName) (DOMAIN\user)"
                        if (-not $cred) { break }
                        $ok = Test-DomainCredential $state.DomainName $cred
                        if ($ok -eq $false) { Write-Log 'That user name or password is wrong - try again.' 'Warn'; $cred = $null; continue }
                        if ($null -eq $ok) { Write-Log "Couldn't reach $($state.DomainName) to check the password - using it as typed." 'Warn' }
                        break
                    }
                    # Encrypted with DPAPI - only this user on this PC can read it. Deleted after the join.
                    if ($cred) { $cred | Export-Clixml -Path $CredFile -Force }

                    if ($config.AskForUser -and -not $Unattended) {
                        $userCred = $null
                        $user = (Read-Host 'Domain user who will use this PC - it signs in as them once after setup (e.g. ahmed.ali, Enter = skip)').Trim()
                        for ($try = 1; $user -and $try -le 3; $try++) {
                            $pw = Read-Host "Password for $user" -AsSecureString
                            $userCred = New-Object System.Management.Automation.PSCredential($user, $pw)
                            $ok = Test-DomainCredential $state.DomainName $userCred
                            if ($ok -eq $false) { Write-Log 'That password is wrong - try again.' 'Warn'; $userCred = $null; continue }
                            if ($null -eq $ok) { Write-Log "Couldn't reach $($state.DomainName) to check the password - using it as typed." 'Warn' }
                            break
                        }
                        if ($userCred) {
                            $userCred | Export-Clixml -Path $UserCredFile -Force
                            $state.UserName = $user
                        }
                    }
                } else {
                    $state.SkipDomainJoin = $true
                }
            }

            foreach ($app in $config.Apps) {
                $reason = Get-SkipReason $app
                if ($reason) { Write-Log "$($app.Name) will be skipped: $reason" 'Warn' }
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
            'Regional'      { Invoke-RegionalStage      $state $config }
            'WindowsUpdate' { Invoke-WindowsUpdateStage $state $config }
            'StoreUpdates'  { Invoke-StoreUpdateStage   $state $config }
            'Apps'          { Invoke-AppsStage          $state $config }
            'DomainJoin'    { Invoke-DomainJoinStage    $state $config }
            'UserSetup'     { Invoke-UserSetupStage     $state $config }
        }
        Set-NextStage $state
    }

    Unregister-ResumeTask
    Remove-Item $CredFile, $UserCredFile -Force -ErrorAction SilentlyContinue

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
    if ($state.UserName -and ($state.Results | Where-Object { $_.Item -eq 'First sign-in' -and $_.Result -like 'Signs in*' })) {
        Write-Log "After the restart the PC signs in as $($state.UserName) and opens classic Outlook and OneDrive." 'Ok'
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
