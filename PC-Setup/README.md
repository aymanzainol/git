# New PC setup

Automates the help-desk build of a new company PC:

1. **Windows Update**: installs everything, restarts, checks again, and repeats until nothing is left.
2. **Microsoft Store and app updates**: starts a Store update scan, then runs `winget upgrade --all`.
3. **Company programs**, in this order: Google Chrome, Foxit PDF Reader, WinRAR, Microsoft 365 Apps, Keyloop Drive, CrowdStrike Falcon Sensor.
4. **Domain join**, renaming the PC at the same time if you gave it a new name.

You answer a few questions at the start: the PC name, the domain, and an account that can join PCs to the domain. After that it runs on its own.

## One-time preparation

Copy this `PC-Setup` folder to a USB stick (or a network share), then:

1. **`config.psd1`**: open it in Notepad and fill in everything marked `CHANGE-ME`:
   - `DomainName`, plus `OUPath` if new PCs go into a specific OU.
   - The Keyloop Drive installer's file name and silent switches.
   - Your CrowdStrike **CID**, in `CID=...`.
2. **`installers\CrowdStrike\`**: put `WindowsSensor.exe` here. Download it from Falcon console → Host setup and management → Sensor downloads.
3. **`installers\Keyloop\`**: put the Keyloop Drive installer here.

The installer files are ignored by git, so they stay on the USB stick and never get committed.

## Building a PC

1. Finish Windows OOBE with a **local admin** account and connect the PC to the network.
2. Plug in the USB stick and double-click **`Start-Setup.cmd`**. Click Yes when Windows asks for admin rights.
3. Answer the questions. Then you can walk away.
4. Each time the PC restarts, **log back in with the same local account**. Setup carries on by itself.
5. At the end you get a summary of what was installed or skipped, and a prompt to restart. The restart completes the domain join.

The script copies itself to `C:\ProgramData\PCSetup\kit` before it starts, so you can remove the USB stick after step 3.

## Things to know

- **It can be re-run safely.** Programs that are already installed are skipped. If something stops it, fix the problem and run `Start-Setup.cmd` again. It asks whether to continue where it left off.
- **Logs** are in `C:\ProgramData\PCSetup\setup.log` and `transcript.log`.
- **The domain password** is saved encrypted (Windows DPAPI, so only that user on that PC can read it). The file is deleted as soon as the join finishes. If the join fails, the script asks for the credentials again, up to 3 tries.
- **Windows Update** skips feature upgrades and "Preview" updates, and gives up after 6 rounds. You can change all of this in `config.psd1`.
- **A missing installer is skipped, not fatal.** If a program isn't configured or its file is missing, that program is skipped with a warning and everything else still installs. Skipped programs are listed in the final summary.
- **Options:** `Setup-NewPC.ps1 -SkipWindowsUpdate` and `-SkipDomainJoin`.

## Adding or changing programs

Add a line to `Apps` in `config.psd1`. Programs install from top to bottom.

```powershell
# From winget. To find an ID, run: winget search "program name"
@{ Name = '7-Zip'; WingetId = '7zip.7zip'; Scope = 'machine' }

# From an installer file in this kit. .msi files get /qn /norestart added automatically.
@{ Name = 'Some App'; Installer = 'installers\SomeApp\setup.msi'; Arguments = ''; Detect = @{ DisplayName = 'Some App*' } }
```

`Detect` tells the script how to recognise a program that's already installed, so re-runs skip it. It accepts one of:

- `Service = 'name'`
- `Path = 'C:\...'`
- `DisplayName = 'name as shown in Programs and Features'`
