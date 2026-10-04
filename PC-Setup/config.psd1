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
    #  Installer : a file in this kit (relative path) or a full/UNC path
    #              .msi files get "/i <file> /qn /norestart" automatically
    #              {KIT} in Arguments = the folder this kit runs from
    #  Detect    : how to tell it's already installed, so re-runs skip it
    #  WaitMinutes : keep checking Detect this long after the installer exits
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

        # Copy your Keyloop Drive installer into installers\Keyloop\ and set the
        # file name + silent switches you normally use.
        @{
            Name      = 'Keyloop Drive'
            Installer = 'installers\Keyloop\CHANGE-ME.exe'
            Arguments = ''
            Detect    = @{ DisplayName = '*Keyloop*' }
        }

        # Copy WindowsSensor.exe (Falcon console > Host setup > Sensor downloads)
        # into installers\CrowdStrike\ and paste your CID (with checksum) below.
        @{
            Name      = 'CrowdStrike Falcon Sensor'
            Installer = 'installers\CrowdStrike\WindowsSensor.exe'
            Arguments = '/install /quiet /norestart CID=CHANGE-ME'
            Detect    = @{ Service = 'CSFalconService' }
        }
    )
}
