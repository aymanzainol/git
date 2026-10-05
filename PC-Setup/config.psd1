@{
    # ---------------------------------------------------------------------
    #  New PC setup - settings
    #  Anything containing CHANGE-ME is treated as "not configured yet":
    #  the script will ask for it (domain) or skip it with a warning (apps).
    # ---------------------------------------------------------------------

    # --- Domain join -----------------------------------------------------
    DomainName         = 'CHANGE-ME.local'   # e.g. 'corp.company.com'
    OUPath             = ''                  # e.g. 'OU=Workstations,DC=corp,DC=company,DC=com' (blank = default Computers container)
                                             # Use an OU that Entra Connect syncs - otherwise Microsoft 365 never registers the PC.
    AskForComputerName = $true               # ask for a new PC name at the start (renamed during the domain join)

    # --- Time zone and keyboards -----------------------------------------
    TimeZone  = 'Arab Standard Time'         # Riyadh (UTC+3). List others with: Get-TimeZone -ListAvailable
    Keyboards = @('en-US', 'ar-SA')          # English (US) + Arabic (Saudi Arabia), for every user

    # --- First sign-in (after the domain join) ----------------------------
    AskForUser          = $true              # ask for the domain user + password; the PC signs in as them once after setup
    OneDriveTenantId    = ''                 # Microsoft 365 tenant ID - also moves Desktop/Documents/Pictures into OneDrive (blank = off)
    RemoveNewOutlookApp = $true              # remove the "new Outlook" app so users open classic Outlook
    WaitForHybridJoinMinutes     = 90        # after the domain-join restart, wait up to this long for Microsoft 365 to register
                                             # the PC (hybrid join) before the user's first sign-in, so Outlook/OneDrive need
                                             # no password. Only when the domain has hybrid join set up. 0 = don't wait.
    BlockWorkplaceJoinWhenHybrid = $true     # once the PC is hybrid joined, block the extra "Sign in to all apps / Allow your
                                             # organization to manage your device" registration (avoids a double registration)
    ForceHybridJoinWait          = $false    # $true if hybrid join is set up by Group Policy (client-side SCP) instead of in AD

    # --- Windows Update --------------------------------------------------
    MaxUpdateRounds   = 6                    # stop after this many search/install rounds (each may reboot)
    ExcludeCategories = @('Upgrades')        # skip feature upgrades (e.g. a surprise jump to a new Windows version)
    ExcludeTitle      = 'Preview'            # skip optional "Preview" updates
    IncludeDrivers    = $true

    # --- App updates (winget) --------------------------------------------
    UpgradeExclude    = @()                  # winget IDs not to update, wildcards ok, e.g. @('Microsoft.VisualStudio*')

    # --- Programs, installed top to bottom -------------------------------
    #  WingetId  : installed from winget (internet)
    #  DownloadUrl : downloaded at install time (Signer = required code-signing company)
    #  Installer : a file in this kit (relative path) or a full/UNC path; '...\*' = newest .exe/.msi in that folder
    #  Arguments : silent switches; AUTO = work them out from the installer type;
    #              CLICKTHROUGH = press Next/Install/Finish in its wizard (Check = boxes to tick)
    #              .msi files get "/i <file> /qn /norestart" automatically
    #              {KIT} in Arguments = the folder this kit runs from
    #  Detect    : how to tell it's already installed, so re-runs skip it
    #  WaitMinutes : keep checking Detect this long after the installer exits
    #  NoWait    : don't wait for the installer to exit, just for Detect (needs Detect + WaitMinutes)
    #              Service = '<service name>' | Path = '<file or folder>' | DisplayName = '<Programs and Features name, wildcards ok>'
    Apps = @(
        @{ Name = 'Google Chrome';      WingetId = 'Google.Chrome';     Scope = 'machine' }
        @{ Name = 'Foxit PDF Reader';   WingetId = 'Foxit.FoxitReader'; Scope = 'machine' }
        @{ Name = 'WinRAR';             WingetId = 'RARLab.WinRAR';     Scope = 'machine' }

        # Office from OfficeSetup.exe (from the Office portal) in installers\Office\.
        # It runs on its own and stays open at the end, so the script just waits for Word to appear.
        # Using Prepare-Office.cmd instead? Set Installer = 'installers\Office\setup.exe',
        # Arguments = '/configure "{KIT}\installers\Office\configuration.xml"' and remove NoWait.
        @{
            Name        = 'Microsoft 365 Apps'
            Installer   = 'installers\Office\OfficeSetup.exe'
            Arguments   = ''
            NoWait      = $true
            Detect      = @{ Path = '%ProgramFiles%\Microsoft Office\root\Office16\WINWORD.EXE' }
            WaitMinutes = 60
        }

        # Keyloop KCML KClient: its setup.exe in installers\Keyloop\.
        # It has no silent mode, so CLICKTHROUGH presses Next / Install / Finish in its wizard,
        # keeping the defaults. To tick options on the way, list them, e.g.
        #   Check = @("Add to 'Start Menu'", 'Add desktop items')
        @{
            Name        = 'Keyloop KCML KClient'
            Installer   = 'installers\Keyloop\setup.exe'
            Arguments   = 'CLICKTHROUGH'
            Check       = @()
            Detect      = @{ DisplayName = '*KClient*' }
            WaitMinutes = 5
        }

        # AnyDesk from anydesk.com (signature checked), starts with Windows.
        @{
            Name            = 'AnyDesk'
            DownloadUrl     = 'https://download.anydesk.com/AnyDesk.exe'
            Signer          = 'AnyDesk Software GmbH'
            Arguments       = '--install "C:\Program Files (x86)\AnyDesk" --start-with-win --silent --create-shortcuts --create-desktop-icon'
            Detect          = @{ Path = '%ProgramFiles(x86)%\AnyDesk\AnyDesk.exe' }
            NoWait          = $true            # its installer keeps running in the background
            WaitMinutes     = 3
            AnyDeskPassword = 'CHANGE-ME'      # unattended-access password
        }

        # Falcon sensor in installers\CrowdStrike\. CID={CID} reads the CID (with checksum) from
        # the CID text file next to it; or write the CID itself, e.g. CID=0123...ABCD-12.
        # A newer sensor with another name: change Installer, or use 'installers\CrowdStrike\*'.
        @{
            Name      = 'CrowdStrike Falcon Sensor'
            Installer = 'installers\CrowdStrike\FalconSensor_Windows 04-27-2026.exe'
            Arguments = '/install /quiet /norestart CID={CID}'
            CidFile   = 'installers\CrowdStrike\CID*'
            Detect    = @{ Service = 'CSFalconService' }
        }
    )
}
