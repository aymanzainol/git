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

    # --- Programs, installed top to bottom -------------------------------
    #  WingetId  : installed from winget (internet)
    #  Installer : a file in this kit (relative path) or a full/UNC path
    #              .msi files get "/i <file> /qn /norestart" automatically
    #  Detect    : how to tell it's already installed, so re-runs skip it
    #              Service = '<service name>' | Path = '<file or folder>' | DisplayName = '<Programs and Features name, wildcards ok>'
    Apps = @(
        @{ Name = 'Google Chrome';      WingetId = 'Google.Chrome';     Scope = 'machine' }
        @{ Name = 'Foxit PDF Reader';   WingetId = 'Foxit.FoxitReader'; Scope = 'machine' }
        @{ Name = 'WinRAR';             WingetId = 'RARLab.WinRAR';     Scope = 'machine' }
        @{ Name = 'Microsoft 365 Apps'; WingetId = 'Microsoft.Office' }

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
