# New PC setup

Automates the help-desk build of a new company PC:

1. **Windows Update**: installs everything, restarts, checks again, and repeats until nothing is left.
2. **Microsoft Store and app updates**: starts a Store update scan, then runs `winget upgrade --all`.
3. **Company programs**, in this order: Google Chrome, Foxit PDF Reader, WinRAR, Microsoft 365 Apps, Keyloop Drive, AnyDesk (with the unattended-access password), CrowdStrike Falcon Sensor. The final summary shows each PC's AnyDesk ID.
4. **Domain join**, renaming the PC at the same time if you gave it a new name.
5. **First sign-in as the user**: after the final restart, the PC signs in once as the domain user it's for, then opens classic Outlook and OneDrive with their account.

You answer a few questions at the start: the PC name, the domain, and an account that can join PCs to the domain. After that it runs on its own.

## One-time preparation

Copy this `PC-Setup` folder to a USB stick (or a network share), then:

1. **`config.psd1`**: open it in Notepad and set `DomainName`, plus `OUPath` if new PCs go into a specific OU. If the zip didn't come with the AnyDesk password filled in, set `AnyDeskPassword` too. `config.psd1` holds that password in plain text. On the PC it sits in an admin-only folder and is deleted at the first sign-in.
2. **Office**: double-click **`Prepare-Office.cmd`** once, on any PC with internet. It puts the Office installer and files (about 4 GB) in `installers\Office`, so new PCs install Office from the USB stick instead of downloading it. Edition and language are set in `installers\Office\configuration.xml`. If you'd rather use your own installer, such as `OfficeSetup.exe`, put it in `installers\Office` and change the Microsoft 365 entry in `config.psd1`.
3. **`installers\CrowdStrike\`**: put the Falcon sensor installer here (any name, for example `FalconSensor_Windows 04-27-2026.exe`), plus a text file whose name starts with `CID` containing your CID with checksum. The script reads the CID from that file, so there's nothing to type into the config.
4. **`installers\Keyloop\`**: put the Keyloop KCML KClient `setup.exe` here (any name). It has no silent mode, so the script clicks through its wizard (Next, Next, Next, Next, Install, Finish), keeping every default, exactly as you would. To tick "Add to 'Start Menu'" or "Add desktop items" on the way, list them in `Check` for Keyloop in `config.psd1`. While setup runs, the PC is kept awake with the screen on, so nothing sleeps or locks in the middle.

The newest `.exe`/`.msi` in each folder is used, so a newer installer with a different name needs no config change.

The installer files are ignored by git, so they stay on the USB stick and never get committed.

## Building a PC

1. Finish Windows OOBE with a **local admin** account and connect the PC to the network.
2. Plug in the USB stick and double-click **`Start-Setup.cmd`**. Click Yes when Windows asks for admin rights.
3. Answer the questions. Then you can walk away.
4. Each time the PC restarts, **log back in with the same local account**. Setup carries on by itself.
5. At the end you get a summary of what was installed or skipped, and a prompt to restart. The restart completes the domain join.

The script copies itself to `C:\ProgramData\PCSetup\kit` before it starts, so you can remove the USB stick after step 3.

## The first sign-in (Outlook and OneDrive)

At the start, after the domain account, the script asks for the **domain user who will use this PC** and their password. It checks the password against the domain straight away. Press Enter to skip this.

After the domain join and the final restart:

- **The PC signs in as that user once, by itself.** The password is kept in Windows' protected LSA store (the same method as Sysinternals Autologon), not in plain text. As soon as that sign-in happens, automatic sign-in is switched off and the password is deleted. The copy of the installers (including the 4 GB of Office files) is deleted at the same time.
- **OneDrive starts and signs in with the Windows account.** If `OneDriveTenantId` is set in `config.psd1`, Desktop, Documents and Pictures also move into OneDrive.
- **Classic Outlook opens and creates the mailbox profile** from the signed-in account. The "Try the new Outlook" switch is hidden, automatic migration to new Outlook is turned off, and the "new Outlook" app is removed (`RemoveNewOutlookApp`).
- Outlook and OneDrive also open once for anyone else who signs in later, if no user was given.

**The first time, classic Outlook asks for the password once.** After the PC is registered to the user in Microsoft 365, it stops asking. If your domain is linked to Microsoft 365 (Entra Connect with hybrid join), the script starts Windows' device registration at the first sign-in instead of waiting for Windows' own schedule. The registration still depends on your directory sync, so it can take a while to finish.

Automatic sign-in doesn't work if a Group Policy shows a logon message ("legal notice") before sign-in. In that case, the user signs in themselves, and Outlook and OneDrive still open.

Logs: `%LOCALAPPDATA%\PCSetup-FirstLogon.log` in the user's profile.

## Things to know

- **It can be re-run safely.** Programs that are already installed are skipped. If something stops it, fix the problem and run `Start-Setup.cmd` again. It asks whether to continue where it left off.
- **Logs** are in `C:\ProgramData\PCSetup\setup.log` and `transcript.log`.
- **The domain password** is saved encrypted (Windows DPAPI, so only that user on that PC can read it). The file is deleted as soon as the join finishes. If the join fails, the script asks for the credentials again, up to 3 tries.
- **Windows Update** shows each update with its size and state, and a progress bar for every download and install. If Windows already has a restart pending, it restarts first. It skips feature upgrades and "Preview" updates (they are still listed, marked `[skipped]`) and gives up after 6 rounds. You can change all of this in `config.psd1`.
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
