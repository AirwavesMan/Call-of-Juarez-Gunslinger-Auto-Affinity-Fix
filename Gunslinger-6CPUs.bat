@echo off
rem Call of Juarez: Gunslinger launcher for Windows 10 and later.
rem This file contains a CMD wrapper followed by an embedded PowerShell script.
rem Exit codes: 0 = success, 1 = operation failed, 2 = PowerShell unavailable.
rem Keep environment changes local. Disabling delayed expansion preserves ! in paths.
setlocal DisableDelayedExpansion
rem Pass arguments through environment variables rather than inserting paths into code.
rem Argument 1 is a game path or mode; argument 2 can be /check.
set "COJ_BATCH=%~f0"
set "COJ_INPUT=%~1"
set "COJ_OPTION=%~2"
rem Sysnative reaches native PowerShell from a 32-bit CMD process on 64-bit Windows.
rem Otherwise, System32 provides the appropriate installed PowerShell.
set "COJ_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "COJ_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%COJ_PS%" (
  echo ERROR: Windows PowerShell is missing.
  pause
  exit /b 2
)
rem Read our own file and execute only the embedded PowerShell section.
rem LastIndexOf avoids matching the marker text inside this command itself.
rem Bypass applies to this invocation; it does not change the system execution policy.
"%COJ_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:COJ_BATCH); & ([ScriptBlock]::Create($t.Substring($t.LastIndexOf('# POWERSHELL-BEGIN'))))"
rem Preserve the script result and keep interactive errors visible.
rem Check and self-test modes never pause, so they can run unattended.
set "COJ_RESULT=%ERRORLEVEL%"
if not "%COJ_RESULT%"=="0" if /i not "%COJ_INPUT%"=="/check" if /i not "%COJ_INPUT%"=="/selftest" if /i not "%COJ_OPTION%"=="/check" pause
exit /b %COJ_RESULT%
# POWERSHELL-BEGIN
# Stop on operational errors so the outer handler can return a consistent exit code.
$ErrorActionPreference = 'Stop'

# Fixed identifiers avoid depending on translated game titles or system output.
$exeName = 'CoJGunslinger.exe'
$appId = '204450'
$check = ($env:COJ_INPUT -eq '/check' -or $env:COJ_OPTION -eq '/check')
$selftest = ($env:COJ_INPUT -eq '/selftest')

# Ordered candidate lists preserve discovery priority. Case-insensitive path keys
# prevent the same installation being added through several discovery sources.
$script:games = New-Object 'System.Collections.Generic.List[object]'
$script:roots = New-Object 'System.Collections.Generic.List[string]'
$script:seenRoots = @{}
$script:seenGames = @{}

# Read the quoted key/value pairs needed from Steam's VDF/ACF files.
# This is a targeted pair reader, not a complete parser of the nested VDF format.
function Read-VdfPairs([string]$file) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
        return
    }
    try {
        $text = [IO.File]::ReadAllText($file)

        # Accept escaped characters, then decode path backslashes and escaped quotes.
        foreach ($m in [regex]::Matches($text, '"((?:\\.|[^"\\])*)"\s*"((?:\\.|[^"\\])*)"')) {
            [PSCustomObject]@{
                Key = $m.Groups[1].Value
                Value = $m.Groups[2].Value.Replace('\\','\').Replace('\"','"')
            }
        }
    } catch {
        Write-Host ('Skipping unreadable Steam file: ' + $file)
    }
}

# Validate a folder or EXE path before recording an installation candidate.
# The executable name and basic PE headers are checked; this is not an authenticity check.
function Add-Game([string]$path, [string]$source, [string]$steam) {
    if ([string]::IsNullOrEmpty($path)) {
        return
    }
    try {
        # Normalize quoted paths and environment variables without wildcard expansion.
        $path = [Environment]::ExpandEnvironmentVariables($path.Trim().Trim('"'))
        if ([IO.Path]::GetFileName($path) -ine $exeName) {
            $path = Join-Path $path $exeName
        }
        $path = [IO.Path]::GetFullPath($path)
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
            return
        }

        # Check the DOS MZ signature, PE header offset/signature and x86/x64 machine type.
        # Bounds checks keep truncated files from being treated as usable executables.
        $stream = [IO.File]::OpenRead($path)
        try {
            if ($stream.Length -lt 64 -or $stream.ReadByte() -ne 77 -or $stream.ReadByte() -ne 90) {
                return
            }
            $reader = New-Object IO.BinaryReader($stream)

            # DOS header offset 0x3C points to the PE header.
            $stream.Position = 60
            $offset = $reader.ReadInt32()
            if ($offset -lt 64 -or $offset -gt $stream.Length-6) {
                return
            }
            $stream.Position = $offset

            # 17744 is the little-endian PE signature (PE followed by two zero bytes).
            if ($reader.ReadUInt32() -ne 17744) {
                return
            }
            $machine = $reader.ReadUInt16()

            # 332 = IMAGE_FILE_MACHINE_I386; 34404 = IMAGE_FILE_MACHINE_AMD64.
            if ($machine -ne 332 -and $machine -ne 34404) {
                return
            }
        }

        # Close the file even when validation returns early.
        finally {
            $stream.Dispose()
        }
        $key = $path.ToLowerInvariant()
        if (!$script:seenGames.ContainsKey($key)) {
            $script:seenGames[$key] = $true
            $script:games.Add([PSCustomObject]@{
                Path = $path
                Source = $source
                Steam = $steam
            })
        }
    } catch {
        Write-Host ('Skipping invalid or inaccessible game path: ' + $path)
    }
}

# Accept only an existing Steam client root with both steam.exe and steamapps.
# Stale registry entries and duplicate roots are expected and are skipped.
function Add-SteamRoot([string]$path) {
    if ([string]::IsNullOrEmpty($path)) {
        return
    }
    try {
        $path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($path.Trim().Trim('"')))
        if ([IO.Path]::GetExtension($path) -ieq '.exe') {
            $path = [IO.Path]::GetDirectoryName($path)
        }
        $key = $path.ToLowerInvariant()
        if ((Test-Path -LiteralPath (Join-Path $path 'steamapps') -PathType Container) -and (Test-Path -LiteralPath (Join-Path $path 'steam.exe') -PathType Leaf) -and !$script:seenRoots.ContainsKey($key)) {
            $script:seenRoots[$key] = $true
            $script:roots.Add($path)
        }
    } catch {
    }
}

# Read known registry value names without parsing localized command-line output.
# Missing or inaccessible optional registry keys must not stop discovery.
function Registry-Values([string]$key, [string[]]$names) {
    try {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        foreach ($name in $names) {
            if ($item.$name) {
                [string]$item.$name
            }
        }
    } catch {
    }
}

# Discover Steam installations first, then local and registered Retail copies.
# Only known locations are inspected; there is no recursive full-disk scan.
function Find-Games {
    # Check per-user, native machine-wide and redirected 32-bit Steam registration.
    foreach ($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam','HKLM:\SOFTWARE\Wow6432Node\Valve\Steam')) {
        foreach ($value in @(Registry-Values $key @('SteamPath','InstallPath','SteamExe'))) {
            Add-SteamRoot $value
        }
    }

    # A running portable Steam client may have no registry entry.
    foreach ($p in @(Get-Process -Name steam -ErrorAction SilentlyContinue)) {
        try {
            Add-SteamRoot $p.MainModule.FileName
        } catch {
        }
    }

    # Probe standard installation folders using environment-provided paths.
    foreach ($base in @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432)) {
        if ($base) {
            Add-SteamRoot (Join-Path $base 'Steam')
        }
    }

    # Also find Steam when this batch is placed inside its directory tree.
    # Limit parent traversal to five levels instead of scanning unrelated directories.
    $ancestor = [IO.DirectoryInfo][IO.Path]::GetDirectoryName($env:COJ_BATCH)
    for ($i = 0; $ancestor -and $i -lt 5; $i++) {
        Add-SteamRoot $ancestor.FullName; $ancestor = $ancestor.Parent
    }
    foreach ($root in $script:roots) {
        # The Steam root is itself a library. Read both historical VDF locations.
        $libraries = @($root)
        foreach ($file in @((Join-Path $root 'steamapps\libraryfolders.vdf'),(Join-Path $root 'config\libraryfolders.vdf'))) {
            foreach ($pair in @(Read-VdfPairs $file)) {
                # New format: numbered objects with a path value. Old format: numbered path values.
                if ($pair.Key -eq 'path' -or $pair.Key -match '^\d+$') {
                    $libraries += $pair.Value
                }
            }
        }
        foreach ($library in @($libraries | Select-Object -Unique)) {
            try {
                $apps = Join-Path $library 'steamapps'
                if (!(Test-Path -LiteralPath $apps -PathType Container)) {
                    continue
                }

                # Require the expected app ID before trusting the manifest's install directory.
                $manifest = @(Read-VdfPairs (Join-Path $apps ('appmanifest_' + $appId + '.acf')))
                $id = @($manifest | Where-Object {
                    $_.Key -eq 'appid'
                })
                $dirs = @($manifest | Where-Object {
                    $_.Key -eq 'installdir'
                })
                if ($id.Count -eq 1 -and $id[0].Value -eq $appId -and $dirs.Count -eq 1) {
                    $dir = $dirs[0].Value

                    # installdir must be one folder name; reject traversal, separators and invalid names.
                    if ($dir -and $dir -ne '.' -and $dir -ne '..' -and $dir.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0) {
                        Add-Game (Join-Path (Join-Path $apps 'common') $dir) 'Steam manifest' $root
                    }
                }

                # Known folder names provide a fallback when a manifest is missing or unreadable.
                foreach ($name in @('Call of Juarez Gunslinger','Call of Juarez - Gunslinger')) {
                    Add-Game (Join-Path (Join-Path $apps 'common') $name) 'Steam folder' $root
                }
            } catch {
                Write-Host ('Skipping obsolete Steam library: ' + $library)
            }
        }
    }

    # Moving the batch beside the EXE also supports unregistered Retail copies.
    $local = [IO.Path]::GetDirectoryName($env:COJ_BATCH)
    Add-Game $local 'Local / Retail' ''
    Add-Game ([IO.Path]::GetDirectoryName($local)) 'Local / Retail' ''

    # Search both registry architectures and per-user Retail registration.
    foreach ($hive in @('HKCU:\Software','HKLM:\SOFTWARE','HKLM:\SOFTWARE\Wow6432Node')) {
        foreach ($vendor in @('Techland','Ubisoft')) {
            foreach ($name in @('Call of Juarez Gunslinger','Call of Juarez: Gunslinger','CoJGunslinger','Gunslinger')) {
                foreach ($path in @(Registry-Values ($hive+'\'+$vendor+'\'+$name) @('InstallPath','InstallDir','InstallLocation','Path'))) {
                    Add-Game $path 'Retail registry' ''
                }
            }
        }

        # Uninstall records can expose InstallLocation or an executable's DisplayIcon path.
        $uninstall = $hive + '\Microsoft\Windows\CurrentVersion\Uninstall'
        foreach ($key in @(Get-ChildItem -LiteralPath $uninstall -ErrorAction SilentlyContinue)) {
            try {
                $entry = Get-ItemProperty -LiteralPath $key.PSPath
                if ($entry.DisplayName -match '(?i)(juarez.*gunslinger|gunslinger.*juarez)') {
                    Add-Game ([string]$entry.InstallLocation) 'Installed game' ''

                    # Handle quoted icon paths and the optional trailing icon index.
                    if ($entry.DisplayIcon -match '^"([^"]+)"|^([^,]+)') {
                        $icon = $Matches[1]
                        if (!$icon) {
                            $icon = $Matches[2]
                        }
                        Add-Game ([IO.Path]::GetDirectoryName($icon)) 'Installed game' ''
                    }
                }
            } catch {
            }
        }
    }
    foreach ($base in @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432)) {
        if (!$base) {
            continue
        }
        foreach ($sub in @('Call of Juarez Gunslinger','Techland\Call of Juarez Gunslinger','Ubisoft\Call of Juarez Gunslinger')) {
            Add-Game (Join-Path $base $sub) 'Retail folder' ''
        }
    }
}

# Compile a small native interop helper in memory; no companion executable is needed.
try {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;

// Pointer-sized native types keep the same helper usable in x86 and x64 hosts.
public static class CoJAffinity
{
    // STARTUPINFO must preserve the field order and widths defined by Win32.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SI
    {
        public int cb;
        public string reserved, desktop, title;
        public int x, y, xSize, ySize, xChars, yChars, fill, flags;
        public short show, reservedSize;
        public IntPtr reservedPtr, input, output, error;
    }

    // PROCESS_INFORMATION contains owned handles plus informational process/thread IDs.
    [StructLayout(LayoutKind.Sequential)]
    struct PI
    {
        public IntPtr process, thread;
        public uint pid, tid;
    }

    // Unicode process creation supports installation paths in any Windows language.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(
        string app, StringBuilder command, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr env, string cwd, ref SI si, out PI pi);

    // Read and update the group-relative affinity mask for a process.
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessAffinityMask(
        IntPtr p, out UIntPtr process, out UIntPtr system);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetProcessAffinityMask(IntPtr p, UIntPtr mask);

    // ResumeThread releases the initial suspension created by CREATE_SUSPENDED.
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr t);

    // Cleanup owns only the process and thread handles returned by CreateProcess.
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll")]
    static extern bool TerminateProcess(IntPtr h, uint code);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    // Select the lowest six allowed bits, or all allowed bits if fewer are available.
    // Each bit represents a logical processor, not necessarily a physical core.
    public static ulong FirstSix(ulong allowed)
    {
        ulong result = 0;
        int count = 0;

        for (int i = 0; i < 64 && count < 6; i++)
        {
            ulong bit = 1UL << i;
            if ((allowed & bit) != 0)
            {
                result |= bit;
                count++;
            }
        }

        // Never interpret an unusable group/job mask as permission to run unrestricted.
        if (result == 0)
        {
            throw new InvalidOperationException(
                "No usable CPU affinity mask (processor group / job restriction).");
        }

        return result;
    }

    // Narrow the process's existing permissions and read back the result.
    public static ulong Apply(IntPtr process)
    {
        UIntPtr p, s;
        if (!GetProcessAffinityMask(process, out p, out s))
        {
            throw new Win32Exception();
        }

        // Intersect process and system masks to avoid requesting unavailable CPUs.
        ulong mask = FirstSix(p.ToUInt64() & s.ToUInt64());
        if (!SetProcessAffinityMask(process, new UIntPtr(mask)))
        {
            throw new Win32Exception();
        }

        if (!GetProcessAffinityMask(process, out p, out s))
        {
            throw new Win32Exception();
        }

        if (p.ToUInt64() != mask)
        {
            throw new InvalidOperationException("Affinity verification failed.");
        }

        return mask;
    }

    // Compute the planned mask without changing the launcher's own affinity.
    public static ulong Probe()
    {
        UIntPtr p, s;
        if (!GetProcessAffinityMask(GetCurrentProcess(), out p, out s))
        {
            throw new Win32Exception();
        }

        return FirstSix(p.ToUInt64() & s.ToUInt64());
    }

    // Set affinity before the game's first instruction, avoiding an initialization race.
    public static uint Launch(string exe, string arguments, string cwd)
    {
        SI si = new SI();
        si.cb = Marshal.SizeOf(si);
        PI pi;

        // Flag 4 is CREATE_SUSPENDED. Null environment inherits the caller's environment.
        // Supply the EXE explicitly and quote argv[0]; use the game folder as its cwd.
        if (!CreateProcess(
            exe, new StringBuilder("\"" + exe + "\" " + arguments),
            IntPtr.Zero, IntPtr.Zero, false, 4, IntPtr.Zero, cwd, ref si, out pi))
        {
            throw new Win32Exception();
        }

        bool resumed = false;
        try
        {
            Apply(pi.process);
            if (ResumeThread(pi.thread) == UInt32.MaxValue)
            {
                throw new Win32Exception();
            }

            resumed = true;
            return pi.pid;
        }
        finally
        {
            // A failed setup must not leave a suspended game process behind.
            if (!resumed)
            {
                TerminateProcess(pi.process, 1);
            }

            // Closing these handles does not stop a successfully resumed game.
            CloseHandle(pi.thread);
            CloseHandle(pi.process);
        }
    }
}
'@

    # Exercise mask selection and verify affinity from inside a harmless child process.
    # This branch does not discover or start the game or Steam.
    if ($selftest) {
        if ([CoJAffinity]::FirstSix(255) -ne 63 -or [CoJAffinity]::FirstSix(10) -ne 10 -or [CoJAffinity]::FirstSix([UInt64]::MaxValue) -ne 63) {
            throw 'Mask tests failed.'
        }

        # An empty allowed mask must fail rather than launch an unrestricted process.
        $zeroFailed = $false
        try {
            [void][CoJAffinity]::FirstSix(0)
        } catch {
            $zeroFailed = $true
        }
        if (!$zeroFailed) {
            throw 'Empty-mask test failed.'
        }

        # Use a unique temporary file for the child's observation of its own affinity.
        $output = Join-Path ([IO.Path]::GetTempPath()) ('coj-affinity-'+[Guid]::NewGuid().ToString()+'.txt')
        $child = '[IO.File]::WriteAllText('''+$output.Replace("'","''")+''',[Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity.ToInt64().ToString())'

        # EncodedCommand preserves quoting and Unicode paths in the child script.
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
        try {
            $childId = [CoJAffinity]::Launch($env:COJ_PS, '-NoProfile -EncodedCommand '+$encoded, [IO.Path]::GetTempPath())
            $until = [DateTime]::UtcNow.AddSeconds(15)
            while (!(Test-Path -LiteralPath $output) -and [DateTime]::UtcNow -lt $until) {
                Start-Sleep -Milliseconds 100
            }
            if (!(Test-Path -LiteralPath $output)) {
                throw 'Child affinity test timed out.'
            }
            $observed = [UInt64][IO.File]::ReadAllText($output)
            if ($observed -ne [CoJAffinity]::Probe()) {
                throw 'Child did not receive the expected CPU limit.'
            }
            Write-Host ('PASS: mask tests and suspended child launch; affinity 0x'+$observed.ToString('X'))
        } finally {
            if (Test-Path -LiteralPath $output) {
                Remove-Item -LiteralPath $output -Force
            }
        }
        exit 0
    }

    # An explicit path takes priority over automatic Steam and Retail discovery.
    if ($env:COJ_INPUT -and !$env:COJ_INPUT.StartsWith('/')) {
        Add-Game $env:COJ_INPUT 'Explicit / Retail' ''
        if ($script:games.Count -eq 0) {
            throw 'The supplied folder / EXE does not contain a readable CoJGunslinger.exe (Windows executable).'
        }
    } else {
        if ($env:COJ_INPUT -and !$check) {
            throw 'Usage: Gunslinger-6CPUs.bat [game folder or EXE] [/check], or /selftest'
        }
        Find-Games
    }

    # Interactive launches offer a manual fallback; /check must remain noninteractive.
    if ($script:games.Count -eq 0) {
        if ($check) {
            throw 'No valid installation found. Place this batch beside CoJGunslinger.exe or pass the game folder as its first argument.'
        }
        Write-Host 'No valid Steam / Retail installation found.'
        $manual = Read-Host 'Enter the game folder or full CoJGunslinger.exe path (empty = cancel)'
        Add-Game $manual 'Manual / Retail' ''
        if ($script:games.Count -eq 0) {
            throw 'No valid game executable selected.'
        }
    }

    # Select the first validated candidate and display the planned CPU mask.
    $game = $script:games[0]
    foreach ($candidate in $script:games) {
        Write-Host ($candidate.Source + ': ' + $candidate.Path)
    }
    $mask = [CoJAffinity]::Probe()
    Write-Host ('Selected: ' + $game.Path)
    Write-Host ('CPU limit: at most 6 logical processors; mask 0x' + $mask.ToString('X'))

    # Stop before any client/game launch or affinity change in detection-only mode.
    if ($check) {
        Write-Host 'Check complete. No game or Steam process was started / changed.'
        exit 0
    }

    # Steam-managed candidates require a usable client. Its own affinity is never changed.
    if ($game.Steam) {
        $steamExe = Join-Path $game.Steam 'steam.exe'
        if (!(Test-Path -LiteralPath $steamExe -PathType Leaf)) {
            throw 'Game found, but steam.exe is missing. Repair Steam or explicitly pass a standalone Retail folder.'
        }
        if (!(Get-Process -Name steam -ErrorAction SilentlyContinue)) {
            [void][Diagnostics.Process]::Start($steamExe)
            Write-Host 'Starting Steam. Waiting for the client...'

            # Wait for the client process, then allow a short initialization interval.
            # This does not guarantee completion of login, updates or first-time setup.
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (!(Get-Process -Name steam -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 250
            }
            if (!(Get-Process -Name steam -ErrorAction SilentlyContinue)) {
                throw 'Steam did not start within 30 seconds.'
            }
            Start-Sleep -Seconds 3
        }
    }

    # Match the full EXE path so other installations are not changed accidentally.
    # An existing matching game is adjusted without starting a duplicate instance.
    $existing = @(Get-Process -Name CoJGunslinger -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.MainModule.FileName -ieq $game.Path
        } catch {
            $false
        }
    })
    if ($existing.Count -gt 0) {
        foreach ($p in $existing) {
            $applied = [CoJAffinity]::Apply($p.Handle)
            Write-Host ('Updated running game PID '+$p.Id+'; mask 0x'+$applied.ToString('X'))
        }
        exit 0
    }

    # Create the game suspended, set/verify affinity, and only then allow it to execute.
    $gameId = [CoJAffinity]::Launch($game.Path,'',[IO.Path]::GetDirectoryName($game.Path))
    Write-Host ('Started game PID '+$gameId+' with affinity set before its first instruction.')

    # Steam/DRM may replace the process. Reapply the limit to matching EXE paths
    # for 60 seconds; externally created replacements have a short detection delay.
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    $found = $false
    $warned = @{}
    while ([DateTime]::UtcNow -lt $deadline) {
        foreach ($p in @(Get-Process -Name CoJGunslinger -ErrorAction SilentlyContinue)) {
            try {
                if ($p.MainModule.FileName -ine $game.Path) {
                    continue
                }
                $applied = [CoJAffinity]::Apply($p.Handle)
                $found = $true
            } catch {
                # Report an inaccessible live process once per PID, avoiding repeated messages.
                if (!$p.HasExited -and !$warned.ContainsKey($p.Id)) {
                    $warned[$p.Id] = $true
                    Write-Host ('Cannot adjust game PID '+$p.Id+': '+$_.Exception.Message)
                }
            } finally {
                $p.Dispose()
            }
        }

        # Poll frequently enough to catch replacements without busy-looping.
        Start-Sleep -Milliseconds 200
    }

    # Verify the surviving matching game processes before reporting success.
    $alive = @(Get-Process -Name CoJGunslinger -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.MainModule.FileName -ieq $game.Path
        } catch {
            $false
        }
    })
    if ($alive.Count -eq 0) {
        throw 'Game is no longer running. Check Steam login and game files. Affinity alone cannot resolve every startup failure.'
    }
    foreach ($p in $alive) {
        $applied = [CoJAffinity]::Apply($p.Handle)
        Write-Host ('Verified PID '+$p.Id+'; mask 0x'+$applied.ToString('X'))
    }
    Write-Host 'The CPU limit remains active until the game exits.'
    exit 0

    # Keep failures visible and return a nonzero exit code to the CMD wrapper.
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
