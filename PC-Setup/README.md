# New PC setup

Automates the help-desk build of a new company PC:

1. **Time zone and keyboard**: sets Riyadh time (Arab Standard Time) and adds the Arabic (Saudi Arabia) keyboard next to English, for every user. Win+Space switches between them.
2. **Windows Update**: installs everything, restarts, checks again, and repeats until nothing is left.
3. **Microsoft Store and app updates**: starts a Store update scan, then runs `winget upgrade --all`.
4. **Company programs**, in this order: Google Chrome, Foxit PDF Reader, WinRAR, Microsoft 365 Apps, Keyloop Drive, AnyDesk (with the unattended-access password), CrowdStrike Falcon Sensor. The final summary shows each PC's AnyDesk ID.
5. **Domain join**, renaming the PC at the same time if you gave it a new name.
6. **First sign-in as the user**: after the final restart, the PC waits for Microsoft 365 to register it (hybrid join), then signs in once as the domain user it's for and opens classic Outlook and OneDrive. With hybrid join there's no password to type.

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

### With hybrid join (no password in Outlook or OneDrive)

Outlook and OneDrive sign in by themselves only when Windows has a Microsoft 365 sign-in token. A domain PC gets that token once it is **hybrid joined**: registered in Microsoft 365 (Entra ID) through Entra Connect. The script checks AD for the hybrid join setting. If it's there:

1. After the domain-join restart, **leave the PC at the sign-in screen**. A background task keeps the PC awake and keeps nudging Windows' own join task until Microsoft 365 has registered the PC. This takes about one Entra Connect sync cycle (30 minutes by default), and at most `WaitForHybridJoinMinutes` (90 by default). **Signing in during the wait cancels it.** The PC then doesn't restart by itself, and Outlook asks for the password once.
2. The PC then **restarts by itself and signs in as the user once**. Windows gets the Microsoft 365 token at that sign-in.
3. **Classic Outlook opens and signs in by itself**, then OneDrive does the same. The user sees no password prompt and no "Allow your organization to manage your device".

Requirements, set up by your AD/Entra admin:

- Hybrid join configured in Entra Connect. Check on any PC: `dsregcmd /status` → **AD Configuration Test : PASS**.
- **New PCs land in an OU that Entra Connect syncs.** Set `OUPath` in `config.psd1` to that OU. If it isn't synced, `dsregcmd /status` keeps showing `error_missing_device` / "The device object by the given id … is not found", and the wait times out. The log then names the PC's OU.
- To shorten the wait, the admin can run `Start-ADSyncSyncCycle -PolicyType Delta` on the Entra Connect server.
- If your hybrid join is set up by Group Policy (client-side SCP) instead of in AD, set `ForceHybridJoinWait = $true`.

Once the PC is hybrid joined, the script also blocks the separate "Sign in to all apps / Allow your organization to manage your device" registration (`BlockWorkplaceJoinWhenHybrid`). Microsoft recommends this, so a domain PC isn't registered twice.

### Without hybrid join, or if the wait times out

The PC signs in as the user, and **Outlook asks for the password once**. OneDrive is started after Outlook has signed in, so it can reuse that sign-in. If Outlook's sign-in doesn't finish, the first sign-in script tries again at the next sign-in or unlock, up to 3 times.

### Everything else

- **The password stays protected.** It is kept in Windows' protected LSA store (the same method as Sysinternals Autologon), not in plain text. At the first sign-in, automatic sign-in is switched off, and the password, the installer copies (including the 4 GB of Office files) and `config.psd1` are deleted.
- **Classic Outlook builds the mail profile** from the signed-in account. The "Try the new Outlook" switch is hidden, automatic migration to new Outlook is off, and the "new Outlook" app is removed (`RemoveNewOutlookApp`).
- **Desktop, Documents and Pictures move into OneDrive** if `OneDriveTenantId` is set in `config.psd1`.
- **A logon message ("legal notice") from Group Policy** pauses the automatic sign-in until someone clicks OK.
- **PC already on the domain?** Double-click **`Setup-User.cmd`**. It asks for the user and their password, sets up all of the above (including the hybrid join wait), and restarts.

Logs: `C:\ProgramData\PCSetup\setup.log` (setup and the hybrid join wait), and `%LOCALAPPDATA%\PCSetup-FirstLogon.log` in the user's profile (Outlook and OneDrive).

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
