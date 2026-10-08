# Call of Juarez: Gunslinger – Launch with a maximum of six threads

## Usage

**Double-click Gunslinger-6CPUs.bat.** The batch file works on its own and requires no companion files. It automatically locates Steam and its libraries, validates the executable, and launches the game with a maximum of six logical processors. This normally corresponds to affinity mask 0x3F (CPU 0–5). If fewer processors are available, only those processors are used.

Requires Windows 10 or later with Windows PowerShell 5.1 / .NET Framework, which are included in standard Windows installations. The batch uses native PowerShell even when launched from a 32-bit environment. Both x86 and x64 are supported. Windows on ARM can only work if the game and its dependencies run under the available x86 emulation; this environment has not been tested. Corporate policies that block PowerShell or enforce Constrained Language mode may prevent execution.

Detection works independently of the Windows or Steam language. It uses registry values, Steam app ID 204450, Unicode file paths, old and new libraryfolders.vdf formats, and appmanifest_204450.acf. Missing libraries, stale registry entries, invalid manifest directories, and missing or invalid executables are skipped. It does not scan the entire disk or execute unchecked commands from manifests. Messages are in English; detection does not depend on localized command output.

If multiple installations are found, the first valid installation is selected and displayed. An explicitly supplied path takes priority. Errors produce a readable message and a nonzero exit code.

## Retail installations or manual selection

Retail detection checks Techland and Ubisoft installation/uninstall registry entries, common installation folders, the batch file's own folder, and its parent folder. For moved or unregistered installations:

- Place the batch beside CoJGunslinger.exe; or
- Drag the game folder or executable onto the batch; or
- Supply a path:

```bat
Gunslinger-6CPUs.bat "D:\Games\Call of Juarez Gunslinger"
```

If no installation is found, the batch asks for the path. A retail edition that requires Steam still needs Steam and a valid license.

## Steam and startup problems with more than 30 threads

The executable is created with CREATE_SUSPENDED: no game instructions run until the batch has set and verified the affinity, then resumed the process. This applies the limit during initialization. Steam is started if needed; login, updates, and first-time setup may still require user input.

If a direct executable launch hands control back to Steam and causes it to start a new game process, a 60-second monitor reapplies the affinity. There is a detection delay for this externally created process. If that relaunch crashes before the monitor can apply the limit, use the batch directly as a Steam launch option (game Properties → General → Launch Options):

```text
"G:\Data\Games\Call of Juarez Gunslinger\Call of Juarez Gunslinger Auto Affinity Fix\Gunslinger-6CPUs.bat" %command%
```

Steam passes the executable path to the batch, which launches the game suspended within Steam's launch context. The batch does not support additional game arguments. Save any existing launch options before replacing them with this setting.

Steam's own affinity is unchanged. The limit remains active for the game process until it exits. Use the batch or the Steam launch option again for subsequent launches. No permanent changes are made to the system, registry, or game files. If the game is already running, the limit is applied to that running process.

The limit is six **logical processors / threads**, which are not necessarily six physical cores: SMT threads count separately. This stays below the reported startup threshold of more than 30 threads. The batch uses up to six allowed processors within one Windows processor group. If unusual processor-group or job restrictions leave no usable affinity mask, it stops with an error message. The fix does not guarantee that other causes of startup failures will be resolved.

## Checks without launching the game

```bat
Gunslinger-6CPUs.bat /check
Gunslinger-6CPUs.bat "D:\Games\Call of Juarez Gunslinger" /check
Gunslinger-6CPUs.bat /selftest
```

/check displays the detected installation and planned affinity mask without starting Steam or the game or changing their affinity. /selftest checks masks for systems with many or few processors and starts a short-lived PowerShell test process with affinity set before execution. Temporary test output is removed afterward.

Exit codes: 0 = success; 1 = detection, launch, or affinity failure; 2 = Windows PowerShell missing. During a normal launch, the window stays open if an error occurs. Administrator privileges are not required as long as the game runs with the same permissions as the batch.

## Sources

- [Steam: Call of Juarez: Gunslinger / app ID 204450](https://store.steampowered.com/app/204450/Call_of_Juarez_Gunslinger/)
- [Microsoft: Launching a process suspended and setting affinity before resuming it](https://devblogs.microsoft.com/oldnewthing/20050817-10/?p=34553)
- [Microsoft: SetProcessAffinityMask and processor groups](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask)
