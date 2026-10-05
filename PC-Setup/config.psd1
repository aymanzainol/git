@{
    # ---------------------------------------------------------------------
    #  New PC setup - settings
    #  Anything containing CHANGE-ME is treated as "not configured yet":
    #  the script will ask for it (domain) or skip it with a warning (apps).
    # ---------------------------------------------------------------------

    # --- Domain join -----------------------------------------------------
    DomainName         = 'CHANGE-ME.local'   # e.g. 'corp.company.com'
    OUPath             = ''                  # e.g. 'OU=Workstations,DC=corp,DC=company,DC=com' (blank = default Computers container)
    AskForComputerName = $true               # ask for a new PC name at the start (renamed during the domain join)

    # --- First sign-in (after the domain join) ----------------------------
    AskForUser          = $true              # ask for the domain user + password; the PC signs in as them once after setup
    OneDriveTenantId    = ''                 # Microsoft 365 tenant ID - also moves Desktop/Documents/Pictures into OneDrive (blank = off)
    RemoveNewOutlookApp = $true              # remove the "new Outlook" app so users open classic Outlook

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
    #  Arguments : silent switches; AUTO = work them out from the installer type
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

        # Office from the installer in installers\Office. Run Prepare-Office.cmd once to put
        # setup.exe + the Office files there (edition/language in configuration.xml).
        # Using your own installer instead, e.g. OfficeSetup.exe from portal.office.com?
        #   Installer = 'installers\Office\OfficeSetup.exe'; Arguments = ''
        @{
            Name        = 'Microsoft 365 Apps'
            Installer   = 'installers\Office\setup.exe'
            Arguments   = '/configure "{KIT}\installers\Office\configuration.xml"'
            Detect      = @{ Path = '%ProgramFiles%\Microsoft Office\root\Office16\WINWORD.EXE' }
            WaitMinutes = 60     # some Office installers return before Office is fully installed
        }

        # Put the Keyloop Drive installer (.exe or .msi) in installers\Keyloop\ - any file name.
        # AUTO works out the silent switches from the installer type; if it can't, put the
        # switches here instead (e.g. '/S' or '/quiet').
        @{
            Name      = 'Keyloop Drive'
            Installer = 'installers\Keyloop\*'
            Arguments = 'AUTO'
            Detect    = @{ DisplayName = '*Keyloop*' }
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

        # Put the Falcon sensor installer in installers\CrowdStrike\ (any name, e.g.
        # FalconSensor_Windows.exe) and a text file starting with CID that contains your CID
        # with checksum (Falcon console > Host setup > Sensor downloads).
        @{
            Name      = 'CrowdStrike Falcon Sensor'
            Installer = 'installers\CrowdStrike\*'
            Arguments = '/install /quiet /norestart CID={CID}'
            CidFile   = 'installers\CrowdStrike\CID*'
            Detect    = @{ Service = 'CSFalconService' }
        }
    )
}
