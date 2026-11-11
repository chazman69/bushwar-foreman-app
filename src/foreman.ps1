# ============================================================================
#  BUSHWAR FOREMAN — team collaboration app for Reforger map building
#  v0.1  (2026-07-06)
#
#  One window for the whole session ritual:
#    START SESSION  = pull latest master (auto-lands any leftover ship)  (then open Tools)
#    SHIP SESSION   = churn-filtered commit + push to master (auto-resolves shared-index clashes)
#  plus live team status (who's building, what landed), and a setup Doctor.
#
#  Design notes:
#   - Windows PowerShell 5.1 + WPF. Zero install; runs from a git clone and
#     self-updates on launch (git pull of its own repo, best-effort).
#   - All project specifics live in foreman.config.json (framework seed —
#     point it at a different repo and Foreman runs that project instead).
#   - Uses GitHub Desktop's bundled git when git isn't on PATH (builders'
#     machines typically have no git.exe on PATH).
#   - The ship logic mirrors collaboration/scripts/putdown.ps1 in the map
#     repo: discard save-churn tiles, never commit the shared generated
#     index. Those rules exist because of the 2026-07-06 live test.
#
#  Smoke test (no window):  powershell -STA -File foreman.ps1 -SmokeTest
# ============================================================================
param(
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$script:ForemanVersion = '0.28.4'
$script:ForemanRoot = Split-Path -Parent $PSScriptRoot   # repo root (src\..)

# ------------------------------------------------------------- taskbar identity
# The visible app is a WPF window hosted by powershell.exe. Windows icons + groups
# a taskbar button by the process's AppUserModelID; with none set, the shell falls
# back to powershell.exe's identity, so the RUNNING button shows the PowerShell
# icon (the title bar/Alt-Tab already show the BW mark via $window.Icon — the
# taskbar just doesn't honour Window.Icon over an AppID). Setting our own
# (unregistered) AppID detaches that grouping, so the button falls back to the
# window's own icon = the BW .ico. Must run before ANY window exists (incl. the
# early setup dialogs). Best-effort: branding must never block launch.
try {
    Add-Type -Namespace Bushwar -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError = true)]
public static extern void SetCurrentProcessExplicitAppUserModelID(
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
'@
    [Bushwar.Shell]::SetCurrentProcessExplicitAppUserModelID('BUSHWAR.Foreman')
} catch { }

# ----------------------------------------------------------------- utilities

function Find-Git {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $desktop = Join-Path $env:LOCALAPPDATA 'GitHubDesktop'
    if (Test-Path $desktop) {
        $apps = Get-ChildItem -Path $desktop -Directory -Filter 'app-*' | Sort-Object Name -Descending
        foreach ($a in $apps) {
            $g = Join-Path $a.FullName 'resources\app\git\cmd\git.exe'
            if (Test-Path $g) { return $g }
        }
    }
    return $null
}

function Git-CredHelperArgs {
    # GitHub Desktop's bundled git doesn't wire up a credential helper for command-line
    # use, so cloning a PRIVATE repo finds no credentials and dies with GitHub's generic
    # "repository not found". Naming Git Credential Manager here makes it pop its own
    # sign-in window when nothing is stored. Empty first value clears any inherited helper
    # (no double prompt); guiPrompt=true forces the GUI over a TTY helper.
    $helper = 'manager'
    try {
        $root = Split-Path -Parent (Split-Path -Parent $script:Git)   # ...\Git  or  ...\resources\app\git
        $modern = $false; $core = $false
        foreach ($d in @('mingw64\bin', 'mingw64\libexec\git-core')) {
            if (Test-Path (Join-Path $root (Join-Path $d 'git-credential-manager.exe'))) { $modern = $true }
            if (Test-Path (Join-Path $root (Join-Path $d 'git-credential-manager-core.exe'))) { $core = $true }
        }
        if (-not $modern -and $core) { $helper = 'manager-core' }
    } catch { }
    return @('-c', 'credential.helper=', '-c', "credential.helper=$helper", '-c', 'credential.guiPrompt=true')
}

function Run-Git {
    param([string]$RepoPath, [string[]]$GitArgs)
    # git writes warnings (e.g. "LF will be replaced by CRLF") AND normal progress
    # (push's "To <url>", "Already on 'master'") to STDERR. Under the script's
    # $ErrorActionPreference='Stop', merging that via 2>&1 makes PowerShell 5.1 throw a
    # NativeCommandError on completely harmless output — which was aborting START/SHIP
    # mid-run and killing the auto-rebase retry. Force non-throwing here; the only real
    # signal of success/failure is git's exit code.
    if ($script:FetchProc -and -not $script:FetchProc.HasExited) {
        # the background stick refresh (git fetch) must finish before anything that moves refs
        $verb = ''
        for ($i = 0; $i -lt $GitArgs.Count; $i++) {
            if ($GitArgs[$i] -eq '-c') { $i++; continue }
            if ($GitArgs[$i] -notlike '-*') { $verb = $GitArgs[$i]; break }
        }
        if (@('fetch', 'pull', 'push', 'rebase', 'commit', 'checkout', 'switch', 'update-ref', 'reset', 'merge') -contains $verb) {
            $script:FetchProc.WaitForExit(120000) | Out-Null
        }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $credArgs = $script:CredArgs
        $out = & $script:Git -C $RepoPath @credArgs @GitArgs 2>&1
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = ($out | Out-String).TrimEnd()
    return @{ Code = $LASTEXITCODE; Out = $text }
}

function Load-Config {
    $cfgPath = Join-Path $script:ForemanRoot 'foreman.config.json'
    if (-not (Test-Path $cfgPath)) { throw "foreman.config.json not found next to src\ — the Foreman clone is incomplete." }
    return (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-LocalConfigPath {
    $dir = Join-Path $env:LOCALAPPDATA 'BushwarForeman'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    return (Join-Path $dir 'local.json')
}

function Load-LocalConfig {
    # returns a hashtable (PS 5.1 ConvertFrom-Json gives PSCustomObject — flatten it)
    $p = Get-LocalConfigPath
    $h = @{}
    if (Test-Path $p) {
        try {
            $obj = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $h[$prop.Name] = $prop.Value }
        } catch { }
    }
    return $h
}

function Save-LocalConfig($obj) {
    $p = Get-LocalConfigPath
    ($obj | ConvertTo-Json) | Out-File -FilePath $p -Encoding utf8
}

function Test-MapRepo([string]$path) {
    # IDENTITY check, not just "is a git repo": must carry the Grand Reef addon
    # marker (map/addon.gproj) so a random clone can never be mistaken for the map.
    if (-not $path) { return $false }
    if (-not (Test-Path $path)) { return $false }
    if (-not (Test-Path (Join-Path $path $script:Cfg.repoMarker))) { return $false }
    $r = Run-Git $path @('rev-parse', '--show-toplevel')
    return ($r.Code -eq 0)
}

function Get-LongPath([string]$path) {
    # 8.3 short names (C:\Users\RUNNER~1\...) are the same folder as the long name a
    # junction reports as its target, but not the same STRING: expand before comparing
    if (-not $path) { return $path }
    try {
        if (-not ('Bushwar.PathNative' -as [type])) {
            Add-Type -Namespace Bushwar -Name PathNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint GetLongPathName(string shortPath, System.Text.StringBuilder longPath, uint size);
'@
        }
        $sb = New-Object System.Text.StringBuilder 1024
        $n = [Bushwar.PathNative]::GetLongPathName($path, $sb, 1024)
        if ($n -gt 0 -and $n -lt 1024) { return $sb.ToString().TrimEnd('\') }
    } catch { }
    return $path.TrimEnd('\')
}

function Test-SamePath([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $false }
    return ((Get-LongPath $a) -ieq (Get-LongPath $b))
}

function Get-DocumentsDir {
    # Workbench writes under the SHELL's Documents folder, which OneDrive (or a moved
    # library) can redirect away from %USERPROFILE%\Documents. An old Workbench folder
    # left in the plain path is not what Workbench reads, so the shell's answer wins.
    $shell = [Environment]::GetFolderPath('MyDocuments')
    if ($shell) { return $shell }
    return (Join-Path $env:USERPROFILE 'Documents')
}

function Get-AddonsRoot {
    if ($script:AddonsRootOverride) { return $script:AddonsRootOverride }   # smoke test only
    return (Join-Path (Get-DocumentsDir) 'My Games\ArmaReforgerWorkbench\addons')
}

function Test-IsMapProjectFolder([string]$dir) {
    # Is this folder a copy of the MAP's own project folder (<repo>\map)? Keyed on the
    # addon GUID inside addon.gproj, NOT on the file name. Every Workshop dependency a
    # builder installs by hand carries its own .gproj and some are named literally
    # addon.gproj, so flagging one of those as a stale map copy would rename a dependency
    # out from under Workbench (the drill has players copying the nine BUSHWAR packs into
    # the tools addons folder, which is the same folder Doctor scans). Unreadable file or
    # a foreign GUID = not the map: never touch someone else's addon.
    if (-not $dir) { return $false }
    $gproj = Join-Path $dir 'addon.gproj'
    if (-not (Test-Path $gproj)) { return $false }
    $guid = $script:Cfg.addonGuid
    if (-not $guid) { return $true }   # no GUID configured (other project), name test only
    try { $text = Get-Content -LiteralPath $gproj -Raw -ErrorAction Stop } catch { return $false }
    return ($text -match [regex]::Escape($guid))
}

function Resolve-RepoFromJunctionTarget([string]$t) {
    # junction may point at the repo root (Mike's pattern) or at <repo>\map (Joe's)
    if (-not $t) { return $null }
    if (Test-Path (Join-Path $t $script:Cfg.repoMarker)) { return $t }
    if (Test-Path (Join-Path $t 'addon.gproj')) { return (Split-Path -Parent $t) }
    return $null
}

function Get-JunctionRepos {
    # every Workbench junction that resolves to a valid map clone — the copy the
    # ENGINE reads is the anchor of truth when multiple clones exist on disk.
    $found = @()
    $root = Get-AddonsRoot
    if (-not (Test-Path $root)) { return $found }
    $items = Get-ChildItem -Path $root -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue
    foreach ($it in $items) {
        if (@('Junction', 'SymbolicLink') -notcontains [string]$it.LinkType) { continue }
        $target = ''
        try { $target = @($it.Target)[0] } catch { $target = '' }
        $repo = Resolve-RepoFromJunctionTarget $target
        if ($repo -and (Test-MapRepo $repo)) {
            $found += , @{ Junction = $it.FullName; Repo = $repo }
        }
    }
    return $found
}

function Get-MapProjectDir {
    # <repo>\map: the folder holding addon.gproj (the marker's parent)
    $proj = Split-Path -Parent ($script:Cfg.repoMarker -replace '/', '\')
    if ($proj) { return (Join-Path $script:MapRepo $proj) }
    return $script:MapRepo
}

function Test-IsLink($item) {
    # junction (mklink /J, what Foreman makes) or directory symlink (mklink /D)
    return (@('Junction', 'SymbolicLink') -contains [string]$item.LinkType)
}

function Repair-WorkbenchLink([switch]$Interactive) {
    # Make Workbench read THIS clone. Runs silently on every launch, so a new builder never
    # needs a call to set it up, and again from Doctor. Junctions need no admin rights.
    # A NEW link is addons\<workbenchLinkName> -> <repo>\map, so addon.gproj sits at the
    # link's root like any other addon; older root-style links keep working
    # (Resolve-RepoFromJunctionTarget reads both). Only Doctor (-Interactive) may move a
    # stale duplicate, because that one needs the builder's yes.
    $lines = @()
    $ok = $false
    $addonsRoot = Get-AddonsRoot
    if (-not (Test-Path $addonsRoot)) {
        # Tools not opened yet on this PC: make the folder now, Workbench adopts it later
        try { New-Item -ItemType Directory -Path $addonsRoot -Force | Out-Null }
        catch { return @{ Ok = $false; Lines = @("[WARN] Foreman couldn't make Workbench's addons folder ($addonsRoot). Screenshot this into the group chat.") } }
    }
    # 1. links: right clone, wrong clone?
    foreach ($j in @(Get-JunctionRepos)) {
        if (Test-SamePath $j.Repo $script:MapRepo) {
            $lines += "[OK]   Workbench reads your copy of the map ($($j.Junction))"
            $ok = $true
        } else {
            $lines += "[FAIL] Workbench is using a different copy of the map than Foreman ($($j.Repo)). Don't build. Screenshot this and ask in the group chat."
        }
    }
    # 2. REAL directories in addons that hold the map = the stale-copy trap: Workbench
    #    reads them, git never sees them, work vanishes. Collect first, act after, and never
    #    look inside a flagged copy or a link (its children are the copy's own map folder,
    #    or, through a link, the REAL clone's: Doctor once renamed a clone's map that way).
    $stale = @()
    foreach ($top in @(Get-ChildItem -LiteralPath $addonsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if (Test-IsLink $top) { continue }
        if ($top.Name -like '*_STALE_BACKUP*') { continue }   # pre-v0.27 backups, already dealt with
        $cands = @($top)
        $isTop = (Test-IsMapProjectFolder $top.FullName) -or (Test-Path (Join-Path $top.FullName $script:Cfg.repoMarker))
        if (-not $isTop) { $cands = @(Get-ChildItem -LiteralPath $top.FullName -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-IsLink $_) }) }
        foreach ($it in $cands) {
            $isProjectCopy = Test-IsMapProjectFolder $it.FullName
            $isRepoCopy = Test-Path (Join-Path $it.FullName $script:Cfg.repoMarker)
            if ($isProjectCopy -or $isRepoCopy) { $stale += , @{ Item = $it; ProjectCopy = $isProjectCopy } }
        }
    }
    $backupRoot = Join-Path (Split-Path -Parent $addonsRoot) 'addons_STALE_BACKUP'
    foreach ($s in $stale) {
        $it = $s.Item
        $lines += "[FAIL] Found a second copy of the map that Workbench reads: $($it.FullName). Anything you build there never ships."
        if (-not $Interactive) {
            $lines += '[WARN] Press Doctor to fix it (it moves that copy out of the way; nothing is deleted).'
            continue
        }
        if ($script:DoctorAutoYes) { $ans = [System.Windows.Forms.DialogResult]::Yes } else {   # smoke test only
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Found a second copy of the map that Workbench reads:`n$($it.FullName)`n`nFix it now? (Moves it to $backupRoot so Workbench stops reading it, and makes sure Workbench reads your real copy. Nothing is deleted.)",
            'BUSHWAR Foreman — Doctor', [System.Windows.Forms.MessageBoxButtons]::YesNo) }
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
            $lines += "[WARN] Second copy left in place. Don't build until it's fixed."
            continue
        }
        try {
            # re-read: never act on a stale listing, and never on anything inside the clone
            $cur = Get-Item -LiteralPath $it.FullName -Force -ErrorAction Stop
            if (Test-IsLink $cur) { continue }
            if ((Get-LongPath $cur.FullName).ToLower().StartsWith((Get-LongPath $script:MapRepo).ToLower() + '\')) { continue }
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            $dest = Join-Path $backupRoot $cur.Name
            $n = 1
            while (Test-Path $dest) { $dest = Join-Path $backupRoot "$($cur.Name)_$n"; $n++ }
            Move-Item -LiteralPath $cur.FullName -Destination $dest
            $lines += "[FIX]  Moved the second copy to $dest. Check it for unshipped work before deleting it (ask in the group chat)."
            if (-not $ok) {
                # keep the path Workbench already knows, pointed at the real clone, same shape
                $target = if ($s.ProjectCopy) { Get-MapProjectDir } else { $script:MapRepo }
                New-Item -ItemType Junction -Path $cur.FullName -Target $target | Out-Null
                $lines += "[FIX]  Workbench now reads your real copy at $($cur.FullName)"
                $ok = $true
            }
        } catch {
            $lines += "[FAIL] Couldn't fix it automatically ($($_.Exception.Message)). Close Workbench and press Doctor again, or ask in the group chat."
        }
    }
    # 3. no link at all -> create one. Not next to an unfixed second copy: Workbench would
    #    then load the same addon twice; Doctor sorts that out first.
    if (-not $ok -and -not ($stale.Count -gt 0 -and -not $Interactive)) {
        $name = $script:Cfg.workbenchLinkName
        if (-not $name) { $name = $script:Cfg.repoFolderName }
        $link = Join-Path $addonsRoot $name
        try {
            $existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
            $resolves = $false
            if ($existing -and (Test-IsLink $existing)) {
                $t = ''
                try { $t = @($existing.Target)[0] } catch { }
                $r = Resolve-RepoFromJunctionTarget $t
                $resolves = [bool]($r -and (Test-MapRepo $r))
            }
            if ($existing -and (Test-IsLink $existing) -and -not $resolves) {
                # a link whose clone was moved or deleted: it resolves to nothing valid
                # (Get-JunctionRepos skipped it), so replace the link itself, never a target
                [System.IO.Directory]::Delete($link)
                $existing = $null
                $lines += "[FIX]  Removed a broken Workbench link at $link"
            }
            if (-not $existing) {
                New-Item -ItemType Junction -Path $link -Target (Get-MapProjectDir) | Out-Null
                $lines += "[FIX]  linked Workbench to your map: $link -> $(Get-MapProjectDir)"
                $ok = $true
            } else {
                $lines += "[WARN] Foreman couldn't link Workbench to the map: a folder called $link is in the way. Screenshot this into the group chat before building."
            }
        } catch {
            $lines += "[WARN] Foreman couldn't link Workbench to the map ($($_.Exception.Message)). Screenshot this into the group chat before building."
        }
    }
    return @{ Ok = $ok; Lines = $lines }
}

function Get-SteamLibraries {
    # every Steam library folder on this PC (registry + libraryfolders.vdf + the defaults)
    $libs = @()
    try {
        $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        if ($sp) {
            $sp = $sp -replace '/', '\'
            $libs += $sp
            $vdf = Join-Path $sp 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf) {
                foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                    $libs += ($m.Groups[1].Value -replace '\\\\', '\')
                }
            }
        }
    } catch { }
    # v0.28.2: the machine-wide Steam path too (HKCU can be missing or stale)
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $ip = (Get-ItemProperty $k -ErrorAction Stop).InstallPath
            if ($ip) {
                $libs += $ip
                $vdf = Join-Path $ip 'steamapps\libraryfolders.vdf'
                if (Test-Path $vdf) {
                    foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                        $libs += ($m.Groups[1].Value -replace '\\\\', '\')
                    }
                }
            }
        } catch { }
    }
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) { if ($pf) { $libs += (Join-Path $pf 'Steam') } }
    $seen = @{}
    $out = @()
    foreach ($lib in $libs) {
        if (-not $lib -or $seen.ContainsKey($lib.ToLower())) { continue }
        $seen[$lib.ToLower()] = 1
        $out += $lib
    }
    return $out
}

function Find-WorkbenchExe {
    # Arma Reforger Tools, in any Steam library on this PC
    foreach ($lib in (Get-SteamLibraries)) {
        $dir = Join-Path $lib 'steamapps\common\Arma Reforger Tools'
        if (-not (Test-Path $dir)) { continue }
        # Steam's own launch option is the SteamDiag build; take it when present
        $pick = Get-ChildItem -Path $dir -Recurse -Depth 2 -Filter 'ArmaReforgerWorkbench*.exe' -ErrorAction SilentlyContinue |
            Sort-Object { if ($_.Name -match 'SteamDiag') { 0 } elseif ($_.Name -match 'Steam') { 1 } else { 2 } } |
            Select-Object -First 1
        if ($pick) { return $pick.FullName }
    }
    return $null
}

$script:BaseGameGuid = '58D0FB3206B6F859'   # ArmaReforger.gproj, the base game every map depends on

# v0.28.1 - the real cause of "Game addon '58D0...' not found" (builder diagnostics,
# 2026-11-10): on some PCs Arma Reforger Tools ships only addons\core; the base game
# (addons\data\ArmaReforger.gproj) lives in the GAME install, steamapps\common\Arma
# Reforger\addons. The Workbench launcher searches it (it's in the launcher's settings),
# but a bare -gproj launch only searches .\addons and Documents\...\ArmaReforgerWorkbench\
# addons, so Foreman's direct launch died while the project list worked. Foreman now
# passes -addonsDir with the game's addons folder when Tools has no base game of its own.
function Find-GameAddonsDir {
    # the Arma Reforger (game) install's addons folder, when it holds the base game.
    # v0.28.2: also Steam's own uninstall entry for the game (app 1874880), which names the
    # install folder even when the library isn't in HKCU/libraryfolders.vdf (a builder's
    # direct launch still went out without -addonsDir, 2026-11-10).
    $dirs = @()
    foreach ($lib in (Get-SteamLibraries)) { $dirs += (Join-Path $lib 'steamapps\common\Arma Reforger') }
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1874880',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1874880')) {
        try { $il = (Get-ItemProperty $k -ErrorAction Stop).InstallLocation; if ($il) { $dirs += $il } } catch { }
    }
    foreach ($d in $dirs) {
        $a = Join-Path $d 'addons'
        if (Test-Path -LiteralPath (Join-Path $a 'data\ArmaReforger.gproj')) { return $a }
    }
    return $null
}

function Test-ToolsHasBaseGame {
    param([string]$Exe)
    return (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Exe) 'addons\data\ArmaReforger.gproj'))
}

function Test-BaseGameMissing {
    # Tools ships without the base game AND the game install can't be found: a direct launch
    # can only end in "Can't find '58D0...' game addon"
    param([string]$Exe)
    if (-not $Exe) { return $false }
    if (Test-ToolsHasBaseGame -Exe $Exe) { return $false }
    return (-not (Find-GameAddonsDir))
}

function Get-WorkbenchAddonsDirs {
    # Pure so it can be smoke-tested: the -addonsDir list for a direct launch, or @() when
    # Tools' own addons folder already has the base game (or the game can't be found).
    param([string]$ToolsAddons, [string]$GameAddons, [string]$DocsAddons)
    if (-not $GameAddons) { return @() }
    if ($ToolsAddons -and (Test-Path -LiteralPath (Join-Path $ToolsAddons 'data\ArmaReforger.gproj'))) { return @() }
    return @(@($ToolsAddons, $GameAddons, $DocsAddons) | Where-Object { $_ })
}

function Get-WorkbenchLaunchArgs {
    # -gproj <map>, plus -addonsDir "<tools>,<game>,<documents>" when the base game is
    # only in the game install
    param([string]$Exe, [string]$Gproj)
    $args2 = @('-gproj', "`"$Gproj`"")
    $dirs = @(Get-WorkbenchAddonsDirs -ToolsAddons (Join-Path (Split-Path -Parent $Exe) 'addons') -GameAddons (Find-GameAddonsDir) -DocsAddons (Get-AddonsRoot))
    if ($dirs.Count -gt 0) { $args2 += @('-addonsDir', "`"$($dirs -join ',')`"") }
    return $args2
}

function Test-BaseGameLaunchFailed {
    # Pure so it can be smoke-tested. Did a Workbench run die because the engine couldn't
    # find the base game ("Game addon '58D0...' not found" / "Can't initialize engine")?
    # v0.27.6: this is EVIDENCE from Workbench's own logs. v0.27.1-v0.27.5 guessed from the
    # Tools folder layout instead, and that guess said "missing base game files" on PCs
    # whose Tools worked fine (two builders), then sent them to the project list.
    param([string[]]$LogTexts)
    $sig = "(?i)can'?t\s+initiali[sz]e\s+engine|game\s+addon\W{0,3}$($script:BaseGameGuid)\W{0,3}\s*not\s+found"
    foreach ($t in $LogTexts) { if ($t -and $t -match $sig) { return $true } }
    return $false
}

function Get-LaunchFailureLines {
    # Pure so it can be smoke-tested. The lines in a failed Workbench start that say what was
    # missing, timestamp stripped, so Doctor can quote them. v0.27.8: a missing addon can be a
    # dependency OF a dependency (e.g. ArmaTerrainCore under one of the packs), which the map's
    # own addon.gproj never lists - only Workbench's log names it.
    param([string[]]$LogTexts, [int]$Max = 3)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($t in $LogTexts) {
        if (-not $t) { continue }
        foreach ($ln in ($t -split "`r?`n")) {
            if ($ln -notmatch '(?i)not\s+found|missing|can''?t\s+(load|find)') { continue }
            if ($ln -notmatch '(?i)addon|[0-9A-F]{16}') { continue }
            $s = ($ln -replace '^\s*\d{1,2}:\d{2}:\d{2}(\.\d+)?\s*', '').Trim()
            if ($s.Length -gt 200) { $s = $s.Substring(0, 200) + '...' }
            if ($s -and -not $out.Contains($s)) { $out.Add($s) }
            if ($out.Count -ge $Max) { return @($out.ToArray()) }
        }
    }
    return @($out.ToArray())
}

function Get-RecentWorkbenchLogTexts([int]$Count = 3) {
    # The start of the newest few Workbench console logs (engine start-up is at the top,
    # and some logs run to hundreds of MB, so only the first 2 MB of each is read).
    $dir = Join-Path (Get-DocumentsDir) 'My Games\ArmaReforgerWorkbench\logs'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter 'console*.log' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First $Count)
    $out = @()
    foreach ($f in $files) {
        try {
            $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $sr = New-Object System.IO.StreamReader($fs)
                $buf = New-Object char[] (2MB)
                $n = $sr.ReadBlock($buf, 0, $buf.Length)
                $out += (New-Object string($buf, 0, $n))
            } finally { $fs.Dispose() }
        } catch { }
    }
    return $out
}

function Test-LogIsForMap {
    # Pure so it can be smoke-tested. Is this Workbench log from a start of THIS map? v0.27.9:
    # builders open other projects too (their own maps), and a failed start of one of those
    # (e.g. missing ArmaTerrainCore, which Grand Reef doesn't use) was blamed on the map.
    # A log counts when it names the map's GUID, its project ID, or (an early failure may
    # print nothing else) the project file Foreman launched, in either slash style.
    param([string]$Text, [string]$Guid, [string]$ProjectId, [string[]]$Paths = @())
    if (-not $Text) { return $false }
    if ($Guid -and $Text.IndexOf($Guid, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        foreach ($v in @(($p -replace '/', '\'), ($p -replace '\\', '/'))) {
            if ($Text.IndexOf($v, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    }
    if ($ProjectId -and $Text -match ('(?i)(?<![A-Za-z0-9_])' + [regex]::Escape($ProjectId) + '(?![A-Za-z0-9_])')) { return $true }
    return $false
}

function Get-MapProjectId {
    # the ID line of the map's addon.gproj (e.g. GrandReef), or '' if unreadable
    try {
        $m = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $script:MapRepo 'map\addon.gproj')), '(?m)^\s*ID\s+"([^"]+)"')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return ''
}

function Get-NewestMapLogText {
    # The newest of the last few Workbench logs that is from a start of this map ('' if none).
    $id = Get-MapProjectId
    $paths = @()
    try {
        $gp = Get-WorkbenchProjectFile
        # the folder + file tail ("Grand Reef\addon.gproj"): the drive/user part of the path
        # may be printed differently (OneDrive, junction vs clone)
        $paths += (Join-Path (Split-Path (Split-Path $gp -Parent) -Leaf) (Split-Path $gp -Leaf))
    } catch { }
    foreach ($t in @(Get-RecentWorkbenchLogTexts 5)) {
        if (Test-LogIsForMap -Text $t -Guid $script:Cfg.addonGuid -ProjectId $id -Paths $paths) { return $t }
    }
    return ''
}

function Test-WorkbenchNeedsLauncher {
    # Open the project list instead of a direct -gproj launch only when the LAST Workbench
    # start OF THIS MAP failed to start the engine (v0.27.9: other projects' logs don't
    # count). No log / clean log = launch directly; one good start clears it (v0.27.8).
    # v0.28.1: a failure from a launch WITHOUT -addonsDir doesn't count once Foreman can now
    # pass one (the game install holds the base game) - that is exactly what it fixes.
    try {
        $t = Get-NewestMapLogText
        if (-not (Test-BaseGameLaunchFailed @($t))) { return $false }
        return -not (Test-AddonsDirWouldFix -LogText $t)
    } catch { return $false }
}

function Test-AddonsDirWouldFix {
    # the failed log's launch had no -addonsDir, and this PC's launch would now add one
    param([string]$LogText)
    if ($LogText -match '(?im)CLI Params:.*-addonsDir') { return $false }
    $exe = Find-WorkbenchExe
    if (-not $exe) { return $false }
    return (@(Get-WorkbenchLaunchArgs -Exe $exe -Gproj 'x') -contains '-addonsDir')
}

function Get-WorkbenchProjectFile {
    # the addon.gproj AS WORKBENCH SEES IT: through the junction, so the path matches the
    # one in Workbench's own project list; the clone's own file as a fallback
    foreach ($j in @(Get-JunctionRepos)) {
        if (-not (Test-SamePath $j.Repo $script:MapRepo)) { continue }
        $direct = Join-Path $j.Junction 'addon.gproj'
        if (Test-Path $direct) { return $direct }
        return (Join-Path $j.Junction ($script:Cfg.repoMarker -replace '/', '\'))
    }
    return (Join-Path $script:MapRepo ($script:Cfg.repoMarker -replace '/', '\'))
}

function Open-Workbench {
    # straight into the map: no project list, no "add existing project". A PC that opens
    # other projects in Tools can opt out: "autoOpenWorkbench": false in local.json.
    # Returns @{ State = opening|notfound|failed|manual; Line = what to log }.
    if ($script:Local.autoOpenWorkbench -eq $false) { return @{ State = 'manual'; Line = '[OK] NOW open Workbench and the Grand Reef world.' } }
    if (Get-WorkbenchRunning) { return @{ State = 'opening'; Line = '[OK] Workbench is already open.' } }
    $exe = Find-WorkbenchExe
    if (-not $exe) {
        return @{ State = 'notfound'; Line = "[WARN] Foreman couldn't find Arma Reforger Tools. Open it from Steam yourself and choose Grand Reef. Press Doctor if it isn't installed." }
    }
    if (Test-BaseGameMissing -Exe $exe) {
        # v0.28.2: a direct launch would only end in "Can't find '58D0...' game addon"; the
        # project list uses the launcher's own game folder setting, so open that instead
        try {
            Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -ErrorAction Stop | Out-Null
        } catch {
            return @{ State = 'failed'; Line = "[WARN] Workbench didn't open ($($_.Exception.Message)). Open it from Steam yourself and choose Grand Reef." }
        }
        return @{ State = 'launcher'; Line = "[WARN] Foreman can't find Arma Reforger (the game) on this PC, and Workbench needs its base game, so the project list is opening instead: pick Grand Reef. If Workbench then says it can't find '58D0FB3206B6F859', install Arma Reforger in Steam. Press Doctor and post the report." }
    }
    if (Test-WorkbenchNeedsLauncher) {
        # a recent direct launch couldn't start the engine on this PC; the project list can
        try {
            Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -ErrorAction Stop | Out-Null
        } catch {
            return @{ State = 'failed'; Line = "[WARN] Workbench didn't open ($($_.Exception.Message)). Open it from Steam yourself and choose Grand Reef." }
        }
        return @{ State = 'launcher'; Line = "[WARN] Workbench's last start on this PC failed with 'Can't initialize engine', so the project list is opening instead: pick Grand Reef. Usual cause: a missing dependency addon - press Doctor to see which." }
    }
    $gproj = Get-WorkbenchProjectFile
    try {
        Start-Process -FilePath $exe -ArgumentList (Get-WorkbenchLaunchArgs -Exe $exe -Gproj $gproj) -WorkingDirectory (Split-Path -Parent $exe) -ErrorAction Stop | Out-Null
    } catch {
        return @{ State = 'failed'; Line = "[WARN] Workbench didn't open ($($_.Exception.Message)). Open it from Steam yourself and choose Grand Reef." }
    }
    return @{ State = 'opening'; Line = '[OK] Opening Workbench on the map (first load takes about a minute).' }
}

function Find-RepoCandidates {
    # bounded disk search: <root>\fireforce and <root>\*\fireforce, marker-validated
    $name = $script:Cfg.repoFolderName
    $roots = @(
        $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Documents\GitHub'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Root -match '^[A-Z]:\\$') { $roots += $d.Root }
    }
    $skip = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', 'AppData', '$Recycle.Bin', 'node_modules', 'OneDriveTemp')
    $seen = @{}
    $hits = @()
    foreach ($root in $roots) {
        if (-not $root) { continue }
        if (-not (Test-Path $root)) { continue }
        $candidates = @((Join-Path $root $name))
        $subs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Where-Object { $skip -notcontains $_.Name }
        foreach ($s in $subs) { $candidates += (Join-Path $s.FullName $name) }
        foreach ($c in $candidates) {
            $key = $c.ToLower()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = 1
            if (Test-MapRepo $c) { $hits += $c }
        }
    }
    return $hits
}

function Choose-Repo([string[]]$paths) {
    # several valid clones and no junction to decide — make the choice obvious
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BUSHWAR Foreman — which map folder is the REAL one?'
    $form.Width = 720; $form.Height = 320; $form.StartPosition = 'CenterScreen'
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Found more than one copy of the map. Pick the one you actually use (newest activity listed first):'
    $lbl.Dock = 'Top'; $lbl.Height = 30
    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = 'Fill'; $list.Font = New-Object System.Drawing.Font('Consolas', 10)
    $sorted = @()
    foreach ($p in $paths) {
        $when = (Run-Git $p @('log', '-1', '--format=%ct|%cr')).Out
        $ts = 0; $rel = 'unknown'
        if ($when -match '^(\d+)\|(.+)$') { $ts = [long]$Matches[1]; $rel = $Matches[2] }
        $sorted += , @{ Path = $p; Ts = $ts; Rel = $rel }
    }
    $sorted = @($sorted | Sort-Object { $_.Ts } -Descending)
    foreach ($s in $sorted) { [void]$list.Items.Add("$($s.Path)   (last activity: $($s.Rel))") }
    $list.SelectedIndex = 0
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'This one'; $ok.Dock = 'Bottom'; $ok.Height = 34
    $ok.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })
    $form.Controls.Add($list); $form.Controls.Add($ok); $form.Controls.Add($lbl)
    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedIndex -ge 0) {
        return $sorted[$list.SelectedIndex].Path
    }
    return $null
}

function Resolve-MapRepo {
    # Anchor of truth: the copy WORKBENCH reads (junction target) outranks everything —
    # a saved answer or disk search can point at a stale duplicate; the junction can't.
    $junctions = @(Get-JunctionRepos)
    $junctionRepo = $null
    if ($junctions.Count -gt 0) { $junctionRepo = $junctions[0].Repo }

    # 1) saved local config — but cross-checked against the junction
    if ($script:Local.repoPath -and (Test-MapRepo $script:Local.repoPath)) {
        if ($junctionRepo -and -not (Test-SamePath $junctionRepo ([string]$script:Local.repoPath))) {
            # Workbench reads a DIFFERENT clone than Foreman was set to — follow Workbench.
            $script:BootNotes += "[FIX] Workbench is linked to $junctionRepo but Foreman was set to $($script:Local.repoPath) — following the Workbench one. (Doctor has the details.)"
            $script:Local.repoPath = $junctionRepo
            Save-LocalConfig $script:Local
            return $junctionRepo
        }
        return $script:Local.repoPath
    }

    # 2) the junction itself
    if ($junctionRepo) {
        $script:Local.repoPath = $junctionRepo
        Save-LocalConfig $script:Local
        return $junctionRepo
    }

    # 3) bounded disk search (marker-validated, so only REAL map clones qualify)
    $hits = @(Find-RepoCandidates)
    if ($hits.Count -eq 1) {
        $script:Local.repoPath = $hits[0]
        Save-LocalConfig $script:Local
        return $hits[0]
    }
    if ($hits.Count -gt 1) {
        $pick = Choose-Repo $hits
        if ($pick) {
            $script:Local.repoPath = $pick
            Save-LocalConfig $script:Local
            return $pick
        }
        throw 'More than one copy of the map found and none chosen. Run Foreman again and pick one.'
    }

    # 4) nothing on disk — offer to download the map. A plain folder off the drive root
    # (the builder's guide path): Documents/Desktop can be OneDrive-synced, and OneDrive
    # fights a repo this size. Nothing is created until the builder says Yes.
    Add-Type -AssemblyName System.Windows.Forms
    $dest = 'C:\BUSHWAR\' + $script:Cfg.repoFolderName
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "Foreman needs the BUSHWAR map on this PC.`n`nYES  = download it now to $dest (about 5 GB, usually 10 to 30 minutes). A black window shows progress, and a GitHub sign-in window may pop up: sign in there. Don't close the black window.`n`nNO  = I already have the map, let me pick its folder.`n`nCANCEL  = quit for now.",
        'BUSHWAR Foreman — first run', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
        try { New-Item -ItemType Directory -Force (Split-Path -Parent $dest) -ErrorAction Stop | Out-Null }
        catch {
            $dest = Join-Path $env:USERPROFILE ('BUSHWAR\' + $script:Cfg.repoFolderName)
            New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
            $script:BootNotes += "[INFO] Couldn't use C:\BUSHWAR, so the map went to $dest instead."
        }
        # room for the map plus Workbench's own files
        try {
            $free = (Get-PSDrive -Name ($dest.Substring(0, 1)) -ErrorAction Stop).Free
            if ($free -lt 15GB) {
                $go = [System.Windows.Forms.MessageBox]::Show(
                    "Only $([math]::Round($free / 1GB, 1)) GB free on that drive. The map needs about 15 GB with room to work.`n`nDownload anyway?",
                    'BUSHWAR Foreman — low disk space', [System.Windows.Forms.MessageBoxButtons]::YesNo)
                if ($go -ne [System.Windows.Forms.DialogResult]::Yes) { throw 'Free up some disk space, then open Foreman again.' }
            }
        } catch [System.Management.Automation.RuntimeException] { if ($_.Exception.Message -like 'Free up*') { throw } }
        # a half-finished earlier download: git won't clone into it, and the old error
        # blamed GitHub sign-in. Move it aside (never delete) and start fresh.
        if ((Test-Path $dest) -and @(Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            $aside = $dest + '_unfinished'
            $n = 1
            while (Test-Path $aside) { $aside = $dest + "_unfinished_$n"; $n++ }
            Rename-Item -LiteralPath $dest -NewName (Split-Path -Leaf $aside)
            $script:BootNotes += "[INFO] Found a half-finished download and moved it to $aside (delete it once the new download works)."
        }
        $cloneArgs = @($script:CredArgs) + @('clone', $script:Cfg.repoUrl, "`"$dest`"")
        $p = Start-Process -FilePath $script:Git -ArgumentList $cloneArgs -Wait -PassThru
        if ($p.ExitCode -ne 0 -or -not (Test-MapRepo $dest)) {
            throw "The download didn't finish. Check your internet, and that you accepted the GitHub invite to the map (github.com/notifications), then open Foreman again to retry."
        }
        $script:Local.repoPath = $dest
        Save-LocalConfig $script:Local
        return $dest
    }
    if ($ans -eq [System.Windows.Forms.DialogResult]::No) {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select your fireforce map folder'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if (Test-MapRepo $dlg.SelectedPath) {
                $script:Local.repoPath = $dlg.SelectedPath
                Save-LocalConfig $script:Local
                return $dlg.SelectedPath
            }
            throw "That folder isn't the map (no $($script:Cfg.repoMarker) inside it). Run Foreman again and pick the folder that came from GitHub."
        }
    }
    throw "No map on this PC yet. Open Foreman again when you're ready to download it."
}

function New-DesktopShortcut {
    $ws = New-Object -ComObject WScript.Shell
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'BUSHWAR Foreman.lnk'
    $lnk = $ws.CreateShortcut($lnkPath)
    $exePath = Join-Path $script:ForemanRoot 'FOREMAN.exe'
    if (Test-Path $exePath) {
        # the native launcher — real exe, BW icon baked in
        $lnk.TargetPath = $exePath
    } else {
        # fallback: hidden powershell straight at the script
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + (Join-Path $script:ForemanRoot 'src\foreman.ps1') + '"'
        $icoPath = Join-Path $script:ForemanRoot 'assets\icon.ico'
        if (Test-Path $icoPath) { $lnk.IconLocation = "$icoPath,0" }
    }
    $lnk.WorkingDirectory = $script:ForemanRoot
    $lnk.Description = 'BUSHWAR Foreman - map team collaboration'
    $lnk.Save()
    return $lnkPath
}

function Get-WorkbenchRunning {
    $procs = Get-Process | Where-Object { $_.ProcessName -like $script:Cfg.workbenchProcessPattern }
    if ($procs) { return $true }
    return $false
}

function Invoke-SelfUpdate {
    # Foreman lives in git — pull itself quietly so everyone runs the latest.
    try {
        $r = Run-Git $script:ForemanRoot @('pull', '--ff-only', '--quiet')
        if ($r.Code -eq 0) { return 'up to date' }
        return 'update skipped'
    } catch { return 'update skipped' }
}

# ----------------------------------------------------- session + ship logic

function Get-LeftoverLandedBy([string]$repo, [string]$branch) {
    # Returns the short sha of the master commit(s) that say "Lands-for: <sha>" for EVERY
    # commit in origin/<branch>..HEAD, or $null if any leftover is not covered.
    $shas = @(((Run-Git $repo @('rev-list', "origin/$branch..HEAD")).Out -split "`r?`n") | Where-Object { $_ -match '^[0-9a-f]{40}$' })
    if ($shas.Count -eq 0) { return $null }
    $by = @()
    foreach ($s in $shas) {
        $hit = (Run-Git $repo @('log', "origin/$branch", '-n', '1', '--format=%h', '--fixed-strings', "--grep=Lands-for: $s")).Out
        if (-not $hit -or -not $hit.Trim()) { $by = $null; break }
        $by += $hit.Trim()
    }
    if ($by) { return (($by | Select-Object -Unique) -join ', ') }
    # v0.28.4: the commit a SHIP makes after its backup exists only on the builder's PC,
    # so whoever combines it by hand can only name the GitHub backup it came from:
    # "Lands-for: refs/backup/<me>/<stamp>". Covered when that backup's map/ matches
    # this PC's HEAD exactly (any later work on this PC makes them differ = not covered).
    $prefix = "$((Get-BackupCfg).Prefix)/$(Get-BackupOwner)/"
    $marks = (Run-Git $repo @('log', "origin/$branch", '-n', '200', '--format=@@LANDS@@ %h%n%B', '--fixed-strings', "--grep=Lands-for: $prefix")).Out
    if (-not $marks) { return $null }
    $cur = ''
    foreach ($line in ($marks -split "`r?`n")) {
        if ($line -match '^@@LANDS@@ ([0-9a-f]{7,40})$') { $cur = $Matches[1]; continue }
        if ($line -match ('^Lands-for: (' + [regex]::Escape($prefix) + '[0-9-]+)\s*$')) {
            $ref = $Matches[1]
            $f = Run-Git $repo @('fetch', '--quiet', '--no-tags', 'origin', "+$($ref):refs/foreman/lands-for")
            if ($f.Code -ne 0) { continue }
            $d = Run-Git $repo @('diff', '--quiet', 'refs/foreman/lands-for', 'HEAD', '--', 'map')
            Run-Git $repo @('update-ref', '-d', 'refs/foreman/lands-for') | Out-Null
            if ($d.Code -eq 0) { return $cur }
        }
    }
    return $null
}

function Test-RebaseInProgress([string]$repo) {
    $gd = (Run-Git $repo @('rev-parse', '--git-dir')).Out
    if (-not $gd) { return $false }
    $gitDir = if ([System.IO.Path]::IsPathRooted($gd)) { $gd } else { Join-Path $repo $gd }
    return (Test-Path (Join-Path $gitDir 'rebase-merge')) -or (Test-Path (Join-Path $gitDir 'rebase-apply'))
}

function Test-SameLayerBody([string]$a, [string]$b) {
    # Two .layer files are the same work if they match once Workbench's regenerated header
    # lines are ignored: BSP (the spatial index), boundMins, boundMaxs - all near the top of
    # the file and rewritten on every save. Streams both files (vegetation layers are ~90 MB).
    $hdr = '^\s*(BSP|boundMins|boundMaxs)(\s|$)'
    $ra = New-Object System.IO.StreamReader($a)
    $rb = New-Object System.IO.StreamReader($b)
    try {
        $na = 0; $nb = 0
        while ($true) {
            do { $la = $ra.ReadLine(); $na++ } while ($la -ne $null -and $na -le 12 -and $la -match $hdr)
            do { $lb = $rb.ReadLine(); $nb++ } while ($lb -ne $null -and $nb -le 12 -and $lb -match $hdr)
            if ($la -eq $null -or $lb -eq $null) { return ($la -eq $null -and $lb -eq $null) }
            if ($la -cne $lb) { return $false }
        }
    } finally { $ra.Dispose(); $rb.Dispose() }
}

function Get-HeaderOnlyLayerSide([string]$repo, [string]$path) {
    # A rebase paused on a conflicted .layer. Returns 'theirs' (the builder's own commit)
    # when master's side only changed the header, 'ours' (master) when the builder's side
    # only changed the header, or $null when both sides really changed it (a human picks).
    $r = Run-Git $repo @('checkout-index', '--stage=all', '--temp', '--', $path)
    if ($r.Code -ne 0 -or $r.Out -notmatch '^(\S+) (\S+) (\S+)\t') { return $null }
    $tmp = @($Matches[1], $Matches[2], $Matches[3])
    $full = @($tmp | ForEach-Object { if ($_ -eq '.') { $null } else { Join-Path $repo $_ } })
    try {
        $base = $full[0]; $ours = $full[1]; $theirs = $full[2]
        if (-not $ours -or -not $theirs) { return $null }               # one side deleted it: a human picks
        if (-not $base) {                                               # both added it
            if (Test-SameLayerBody $ours $theirs) { return 'ours' }
            return $null
        }
        if (Test-SameLayerBody $ours $base) { return 'theirs' }         # master: header-only
        if (Test-SameLayerBody $theirs $base) { return 'ours' }         # builder: header-only
        return $null
    } catch {
        return $null
    } finally {
        foreach ($f in $full) { if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    }
}

function Resolve-SharedRebase([string]$repo, [string]$master) {
    # A rebase has paused on conflict. Proven merge model (collaboration/terrain-sculpting.md,
    # verified live in PR #82): sculpt geometry lives in disjoint per-tile files and never
    # cross-conflicts; the ONLY things that clash are the shared *regenerable* index files
    # (GrandReef.terr, tileMap.conf, resourceDatabase.rdb). Rule: master wins on those and
    # Workbench rebuilds them on the next save — zero sculpt lost. So auto-resolve the shared
    # set (--ours == master's version during a rebase), continue, push. If a REAL per-tile
    # file conflicts, two people changed the same non-shared file (the same terrain tile,
    # or — more often now — the same world layer) — that's the one human hard-stop.
    $shared = @($script:Cfg.terrain.sharedRegenFiles)
    $resolved = @{}
    $layers = @{}
    $guard = 0
    while (Test-RebaseInProgress $repo) {
        if ($guard++ -gt 200) { return @{ Ok = $false; Bad = @('(rebase did not converge)') } }
        $u = (Run-Git $repo @('diff', '--name-only', '--diff-filter=U')).Out
        $unmerged = @()
        if ($u) { $unmerged = @($u -split "`r?`n" | Where-Object { $_ }) }
        if ($unmerged.Count -gt 0) {
            # v0.27.4: a world layer where one side changed ONLY Workbench's regenerated
            # header (BSP / boundMins / boundMaxs) isn't a real clash - keep the side with
            # the real edits (Malvia vs Hyrax on default.layer, 2026-11-09).
            $layerPicked = @{}   # path -> side kept, for this paused commit
            foreach ($p in @($unmerged | Where-Object { $shared -notcontains $_ -and $_ -like '*.layer' })) {
                $side = Get-HeaderOnlyLayerSide $repo $p
                if ($side) {
                    Run-Git $repo @('checkout', "--$side", '--', $p) | Out-Null
                    Run-Git $repo @('add', '--', $p) | Out-Null
                    $layerPicked[$p] = $side
                }
            }
            $bad = @($unmerged | Where-Object { $shared -notcontains $_ -and -not $layerPicked.ContainsKey($_) })
            if ($bad.Count -gt 0) { return @{ Ok = $false; Bad = $bad } }
            foreach ($k in $layerPicked.Keys) { $layers[$k] = $layerPicked[$k] }
            foreach ($p in @($unmerged | Where-Object { -not $layerPicked.ContainsKey($_) })) {
                Run-Git $repo @('checkout', '--ours', '--', $p) | Out-Null   # --ours == master during a rebase
                Run-Git $repo @('add', '--', $p) | Out-Null
                $resolved[$p] = 1
            }
            Run-Git $repo @('-c', 'core.editor=true', 'rebase', '--continue') | Out-Null
        } else {
            # No unmerged files. A patch can legitimately become EMPTY (its only change
            # was a shared regen file master already has) — that's safe to --skip. But a
            # blind --skip drops the WHOLE commit, so we must never skip a non-empty one:
            # if --continue fails and the tree still differs from HEAD, real work is on
            # the line — abort and hard-stop instead of silently losing it.
            $c = Run-Git $repo @('-c', 'core.editor=true', 'rebase', '--continue')
            if ($c.Code -ne 0 -and (Test-RebaseInProgress $repo)) {
                $empty = (Run-Git $repo @('diff', '--quiet', 'HEAD')).Code -eq 0   # 0 = tree matches HEAD = patch really is empty
                if ($empty) {
                    Run-Git $repo @('rebase', '--skip') | Out-Null                 # nothing of yours to lose
                } else {
                    Run-Git $repo @('rebase', '--abort') | Out-Null
                    return @{ Ok = $false; Bad = @('(rebase stalled on a commit that still has changes — not skipped, so nothing was dropped)') }
                }
            }
        }
    }
    return @{ Ok = $true; Resolved = @($resolved.Keys); Layers = $layers }
}

function Get-RepoState {
    $repo = $script:MapRepo
    $branch = (Run-Git $repo @('rev-parse', '--abbrev-ref', 'HEAD')).Out
    $dirty = (Run-Git $repo @('status', '--porcelain')).Out
    $dirtyCount = 0
    if ($dirty) { $dirtyCount = @($dirty -split "`r?`n").Count }
    $behind = 0; $ahead = 0
    $r = Run-Git $repo @('rev-list', '--left-right', '--count', "origin/$($script:Cfg.defaultBranch)...HEAD")
    if ($r.Code -eq 0 -and $r.Out -match '^(\d+)\s+(\d+)$') {
        $behind = [int]$Matches[1]; $ahead = [int]$Matches[2]
    }
    return @{ Branch = $branch; DirtyCount = $dirtyCount; Behind = $behind; Ahead = $ahead }
}

function Invoke-StartSession {
    # Direct-to-master model (design ruling 2026-07-06): sessions live on master.
    $repo = $script:MapRepo
    if (Get-WorkbenchRunning) { throw 'Workbench is already open. Close it fully, then press START SESSION again.' }
    # tripwire: if Workbench is linked to a DIFFERENT clone than the one Foreman
    # manages, building would go into one copy and shipping from another.
    $junctions = @(Get-JunctionRepos)
    if ($junctions.Count -gt 0) {
        $match = $false
        foreach ($j in $junctions) { if (Test-SamePath $j.Repo $repo) { $match = $true } }
        if (-not $match) {
            throw "Workbench is linked to a DIFFERENT map copy ($($junctions[0].Repo)) than Foreman manages ($repo). Run the Doctor — it fixes this — before building."
        }
    }
    $notes = @()
    $dirty = (Run-Git $repo @('status', '--porcelain')).Out
    if ($dirty) {
        # REAL work blocks; engine noise (save-churn tiles, the excluded index) is
        # cleaned automatically — noise must never wedge the buttons.
        $plan = Get-ShipPlan
        $real = $plan.RealTiles.Count + $plan.Other.Count
        if ($real -gt 0) {
            throw "You have UNSHIPPED work from a previous session ($real item(s)). Hit SHIP SESSION first. Nothing was changed."
        }
        foreach ($n in $plan.ChurnTiles.Keys) {
            foreach ($p in $plan.ChurnTiles[$n]) { Run-Git $repo @('checkout', '--', $p) | Out-Null }
        }
        foreach ($p in $plan.Excluded) { Run-Git $repo @('checkout', '--', $p) | Out-Null }
        $notes += "[FIX] cleaned engine noise left from last session ($($plan.ChurnTiles.Count) churn tile(s), shared index) - nothing of yours was touched."
    }

    $r = Run-Git $repo @('switch', $script:Cfg.defaultBranch)
    if ($r.Code -ne 0) { $r = Run-Git $repo @('checkout', $script:Cfg.defaultBranch) }
    if ($r.Code -ne 0) { throw "Couldn't switch to $($script:Cfg.defaultBranch): $($r.Out)" }

    # leftover committed-but-unpushed work (e.g. a ship that lost internet)?
    # rebase it onto the team's latest and push it — finish the old ship first.
    Run-Git $repo @('fetch', 'origin', '--quiet') | Out-Null
    $counts = (Run-Git $repo @('rev-list', '--left-right', '--count', "origin/$($script:Cfg.defaultBranch)...HEAD")).Out
    $ahead = 0
    if ($counts -match '^\d+\s+(\d+)$') { $ahead = [int]$Matches[1] }
    if ($ahead -gt 0) {
        $subjects = (Run-Git $repo @('log', "origin/$($script:Cfg.defaultBranch)..HEAD", '--format=%s')).Out
        # off-PC backup BEFORE the rebase touches it (no backup, no landing)
        try {
            $bk = Backup-Session -Label 'start'
        } catch {
            throw "Couldn't back up your leftover commit(s) to GitHub, so nothing was pulled or pushed - your work is safe on this PC. ($($_.Exception.Message))"
        }
        if ($bk) { $notes += "[OK] Backed up your leftover work to GitHub: $($bk.Remote)" }
        # v0.28.3: a teammate may already have landed this work for you (e.g. after a layer
        # clash someone combined it by hand) - master then carries a "Lands-for: <sha>" line
        # for every leftover commit. Sync to master instead of re-landing (which would clash
        # again forever). Only when EVERY leftover is covered; reset --keep refuses rather
        # than overwrite anything uncommitted.
        $landedBy = Get-LeftoverLandedBy $repo $script:Cfg.defaultBranch
        if ($landedBy) {
            $r = Run-Git $repo @('reset', '--keep', "origin/$($script:Cfg.defaultBranch)")
            if ($r.Code -ne 0) { throw "Your leftover work is already on the team map, but Foreman couldn't sync to it. Nothing was lost (backed up). Post in the group chat. ($($r.Out))" }
            $notes += "[FIX] your leftover commit(s) from last time ($($subjects -join '; ')) were already landed on the team map by a teammate ($landedBy) - synced to it, nothing lost."
            $ahead = 0
        }
    }
    if ($ahead -gt 0) {
        # stick GATE: leftover base-layer edits wait while someone else holds the stick
        $leftBase = @(Get-BaseLayerPaths @(((Run-Git $repo @('diff', '--name-only', "origin/$($script:Cfg.defaultBranch)...HEAD")).Out -split "`r?`n")))
        if ($leftBase.Count -gt 0) {
            $s = Get-LayerStick
            $holder = ''
            if ($s) { $holder = $s.Holder }
            if ((Get-StickGate $leftBase $holder (Get-MyName)) -eq 'blocked') {
                $bref = ''
                if ($bk) { $bref = $bk.Remote }
                throw "Your unshipped commit(s) from last time: $(Get-StickWaitMessage $leftBase $s $bref 'press START SESSION again to land it') (Until it lands you can't pull the team's latest.)"
            }
        }
        $r = Run-Git $repo @('pull', '--rebase', 'origin', $script:Cfg.defaultBranch)
        if ($r.Code -ne 0) {
            # rebase paused on conflict — auto-resolve the shared index files (master wins),
            # hard-stop only on a genuine same-tile clash.
            $res = Resolve-SharedRebase $repo $script:Cfg.defaultBranch
            if (-not $res.Ok) {
                Run-Git $repo @('rebase', '--abort') | Out-Null
                throw "CONFLICT landing a leftover commit — you and a teammate changed the same file(s): $($res.Bad -join ', '). If those are world layers, you both worked the same layer - a human picks how to combine them. Your work is safe locally. STOP and post in the group chat. Once a teammate has landed the combined version, press START SESSION again - it syncs by itself."
            }
            if ($res.Resolved.Count -gt 0) {
                $names = ($res.Resolved | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
                $notes += "[FIX] auto-merged $($res.Resolved.Count) shared index file(s) while landing leftover work (master wins, Workbench regenerates them; your sculpts untouched): $names"
            }
            if ($res.Layers -and $res.Layers.Count -gt 0) {
                $names = ($res.Layers.Keys | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
                $notes += "[FIX] $names clashed only in Workbench's auto-generated header (BSP/bounds) - kept the side with the real edits, nothing lost; Workbench rebuilds the header on next save."
            }
        }
        $r = Run-Git $repo @('push', 'origin', $script:Cfg.defaultBranch)
        if ($r.Code -ne 0) { throw "Couldn't push your leftover work (internet? sign-in?) — it's safe locally; ask in chat. ($($r.Out))" }
        $notes += "[FIX] shipped $ahead leftover commit(s) from a previous session: $subjects"
    } else {
        $r = Run-Git $repo @('pull', '--ff-only', 'origin', $script:Cfg.defaultBranch)
        if ($r.Code -ne 0) { throw "Couldn't pull $($script:Cfg.defaultBranch) cleanly — DON'T build. Post in the group chat. ($($r.Out))" }
    }

    # v0.25: name a missing/stale props addon BEFORE Workbench opens (never blocks - the
    # ship-time PREFAB GUARD is the real protection).
    try {
        $dep = Get-DependencyWarnings
        if ($dep.Summary) { $notes += $dep.Summary }
    } catch { }
    try { $notes += @(Get-MissingDependencyLines | Where-Object { $_ -like '`[WARN`]*' }) } catch { }

    return @{ Branch = $script:Cfg.defaultBranch; Notes = $notes }
}

function Get-ChangedPaths {
    $repo = $script:MapRepo
    $lines = (Run-Git $repo @('status', '--porcelain')).Out
    $paths = @()
    if ($lines) {
        foreach ($line in ($lines -split "`r?`n")) {
            if ($line.Length -lt 4) { continue }
            $p = $line.Substring(3)
            if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }
            $p = $p.Trim('"')
            if ($p.EndsWith('/')) { continue }
            $paths += $p
        }
    }
    return $paths
}

function Get-ShipPlan {
    # Classify the working tree: real tiles / churn tiles / excluded shared / normal files.
    $changed = Get-ChangedPaths
    $tileRe = $script:Cfg.terrain.tileRegex
    $never = @($script:Cfg.terrain.neverCommit)

    $tiles = @{}
    $other = @()
    $excluded = @()
    foreach ($p in $changed) {
        if ($never -contains $p) { $excluded += $p; continue }
        $m = [regex]::Match($p, $tileRe)
        if ($m.Success) {
            $n = $m.Groups[2].Value
            if (-not $tiles.ContainsKey($n)) { $tiles[$n] = @() }
            $tiles[$n] += $p
        } else {
            $other += $p
        }
    }
    # What counts as real per-tile work:
    #   .bterr (heightmap source) changed -> you SCULPTED the tile. Ship.
    #   _layer (surface mask) changed     -> you PAINTED the tile. Ship.
    #   only .ttile / _normal changed     -> pure derived churn (serialize / normal regen).
    #                                        Drop; each machine rebuilds it locally.
    $srcRe   = [regex]::Escape($script:Cfg.terrain.sculptSourceExtension) + '$'   # .bterr
    $paintRe = [regex]::Escape($script:Cfg.terrain.paintSourceMarker)             # _layer
    $realTiles = @{}
    $churnTiles = @{}
    foreach ($n in $tiles.Keys) {
        $group = $tiles[$n]
        if (@($group | Where-Object { $_ -match $srcRe -or $_ -match $paintRe }).Count -gt 0) { $realTiles[$n] = $group }
        else { $churnTiles[$n] = $group }
    }
    return @{ RealTiles = $realTiles; ChurnTiles = $churnTiles; Excluded = $excluded; Other = $other }
}

$script:ChurnCache = @{}

function Test-LayerIsChurn([string]$relPath) {
    # $true ONLY when a changed layer holds exactly the same world as HEAD (every entity,
    # prefab, name, position and property; Workbench's regrouping/reordering and float
    # jitter under 1 mm ignored) - a pure re-save that's safe to drop. v0.21 compared the
    # entity COUNT, which also matched when road points were moved or buildings nudged,
    # so those real edits were silently reverted (Joe, Mike's side, 2026-10-18). Any
    # doubt - no committed copy, deleted file, read/parse trouble - answers $false, and
    # the edit ships. Cached per file state: the big layers take seconds to compare.
    $repo = $script:MapRepo
    $full = Join-Path $repo $relPath
    if (-not (Test-Path -LiteralPath $full)) { return $false }
    try {
        $fi = Get-Item -LiteralPath $full
        $headSha = (Run-Git $repo @('rev-parse', '-q', '--verify', "HEAD:$relPath")).Out
        if (-not $headSha) { return $false }
        $key = "$relPath|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)|$headSha"
        if ($script:ChurnCache.ContainsKey($key)) { return $script:ChurnCache[$key] }
        Initialize-LayerScan
        $head = Read-GitText 'HEAD' $relPath
        if ($null -eq $head) { return $false }
        $work = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
        $same = [Bushwar.LayerCanon]::SameContent($work, $head)
        $script:ChurnCache[$key] = $same
        return $same
    } catch {
        return $false
    }
}

# ------------------------------------------------------- safety snapshot (v0.26)
# Before SHIP filters, repairs or discards ANYTHING, the whole session (every changed
# and new file except the derived tile churn and the never-commit index) is written into
# a local git ref: refs/foreman/safety/<yyyyMMdd-HHmmss>. Nothing in the working tree,
# the index or master changes. Backup-Session then copies it to GitHub (see below), so
# it survives a dead PC too. If a ship ever drops something it shouldn't have, it's one
# command away (README "Getting work back"). Git stores unchanged files once, so
# snapshots are cheap; the newest $SafetyKeep are kept on this PC.
$script:SafetyKeep = 60

function Save-SafetySnapshot {
    param($Plan, [string]$Label = 'ship')
    $repo = $script:MapRepo
    if (-not (Run-Git $repo @('status', '--porcelain')).Out) { return $null }
    # everything changed or new, except the derived tile churn (whole tile folders are left
    # out, then the tiles you really sculpted/painted are added back) and the never-commit index
    $excl = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($Plan.ChurnTiles.Keys)) {
        foreach ($p in @($Plan.ChurnTiles[$n])) {
            $d = $p.Substring(0, $p.LastIndexOf('/'))
            if (-not $excl.Contains($d)) { $excl.Add($d) }
        }
    }
    foreach ($p in @($script:Cfg.terrain.neverCommit)) { $excl.Add($p) }
    # git add exits 1 when an exclude names an untracked file that .gitignore already
    # ignores, and that stopped every v0.26 ship at "no backup" (Malvia, 2026-10-21:
    # map/resourceDatabase.rdb is in fireforce's .gitignore). add -A never picks an
    # ignored file up anyway, so those excludes are dropped. check-ignore leaves tracked
    # files out of its answer, so a tracked never-commit file stays excluded.
    if ($excl.Count -gt 0) {
        $ign = (Run-Git $repo (@('-c', 'core.quotePath=false', 'check-ignore', '--') + $excl.ToArray())).Out
        if ($ign) {
            foreach ($p in @($ign -split "`r?`n" | Where-Object { $_ })) { [void]$excl.Remove($p.Trim('"')) }
        }
    }
    $real = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($Plan.RealTiles.Keys)) { foreach ($p in @($Plan.RealTiles[$n])) { $real.Add($p) } }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    # A git killed mid-snapshot (Foreman closed, PC slept) leaves <idx>.lock behind, and
    # Windows reuses PIDs, so a $PID-only name later hit "Unable to create ...idx.lock:
    # File exists" and stopped every ship (Hyrax, 2026-11-08). Unique name per call, and
    # sweep leftovers older than a day.
    Get-ChildItem -LiteralPath $env:TEMP -Filter 'foreman-safety-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $tag = "$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $idx = Join-Path $env:TEMP "foreman-safety-$tag.idx"
    $list = Join-Path $env:TEMP "foreman-safety-$tag.txt"
    $prevIdx = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $idx
        $r = Run-Git $repo @('read-tree', 'HEAD')
        if ($r.Code -ne 0) { throw "read-tree: $($r.Out)" }
        $addArgs = @('add', '-A', '--', '.') + @($excl | ForEach-Object { ":(exclude)$_" })
        $r = Run-Git $repo $addArgs
        if ($r.Code -ne 0) { throw "add: $($r.Out)" }
        if ($real.Count -gt 0) {
            [System.IO.File]::WriteAllLines($list, $real.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
            $r = Run-Git $repo @('--literal-pathspecs', 'add', '-A', "--pathspec-from-file=$list")
            if ($r.Code -ne 0) { throw "add tiles: $($r.Out)" }
        }
        $names = (Run-Git $repo @('diff', '--cached', '--name-only', 'HEAD')).Out
        $count = 0
        if ($names) { $count = @($names -split "`r?`n" | Where-Object { $_ }).Count }
        if ($count -eq 0) { return $null }
        $tree = (Run-Git $repo @('write-tree')).Out
        if (-not $tree) { throw 'write-tree returned nothing' }
    } finally {
        if ($prevIdx) { $env:GIT_INDEX_FILE = $prevIdx } else { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $idx, "$idx.lock", $list -Force -ErrorAction SilentlyContinue
    }
    $r = Run-Git $repo @('-c', 'user.name=BUSHWAR Foreman', '-c', 'user.email=foreman@localhost',
        'commit-tree', $tree, '-p', 'HEAD', '-m', "Foreman safety snapshot ($Label) $stamp - $count file(s)")
    if ($r.Code -ne 0 -or -not $r.Out) { throw "commit-tree: $($r.Out)" }
    $ref = "refs/foreman/safety/$stamp"
    $r2 = Run-Git $repo @('update-ref', $ref, $r.Out)
    if ($r2.Code -ne 0) { throw "update-ref: $($r2.Out)" }
    # keep the newest N
    $all = (Run-Git $repo @('for-each-ref', '--sort=-refname', '--format=%(refname)', 'refs/foreman/safety/')).Out
    if ($all) {
        $refs = @($all -split "`r?`n" | Where-Object { $_ })
        if ($refs.Count -gt $script:SafetyKeep) {
            foreach ($old in $refs[$script:SafetyKeep..($refs.Count - 1)]) { Run-Git $repo @('update-ref', '-d', $old) | Out-Null }
        }
    }
    return @{ Ref = $ref; Files = $count; Sha = $r.Out; Tree = $tree }
}

function Get-SafetySnapshots {
    $out = (Run-Git $script:MapRepo @('for-each-ref', '--sort=-refname', '--format=%(refname:short)  %(subject)', 'refs/foreman/safety/')).Out
    if (-not $out) { return @() }
    return @($out -split "`r?`n" | Where-Object { $_ })
}

# ------------------------------------------------------- off-PC backup (v0.26)
# chazman69, 2026-10-20: everyone's work must be recoverable no matter what, before any
# push. So every snapshot is also pushed to GitHub as refs/backup/<git name>/<stamp>:
# before SHIP, before START lands a leftover commit, before a stick tap, and every
# backup.autoMinutes while Foreman is open (Invoke-AutoBackup). These are NOT branches:
# they don't show in GitHub's branch list and a normal clone/fetch never downloads them.
# Each PC can only back up its own unshipped work, so every builder runs Foreman.
function Get-BackupCfg {
    $c = @{ Prefix = 'refs/backup'; Keep = 60; Minutes = 30 }
    if ($script:Cfg.PSObject.Properties['backup']) {
        $b = $script:Cfg.backup
        if ($b.PSObject.Properties['remoteRefPrefix'] -and $b.remoteRefPrefix) { $c.Prefix = ([string]$b.remoteRefPrefix).TrimEnd('/') }
        if ($b.PSObject.Properties['keepPerPerson'] -and [int]$b.keepPerPerson -gt 0) { $c.Keep = [int]$b.keepPerPerson }
        if ($b.PSObject.Properties['autoMinutes']) { $c.Minutes = [int]$b.autoMinutes }
    }
    return $c
}

function Get-BackupOwner {
    # ref-safe folder for this PC's backups: the git name (e.g. "The Bushwar Team" ->
    # The-Bushwar-Team), else the PC name
    $n = Get-MyName
    if (-not $n) { $n = $env:COMPUTERNAME }
    $n = [regex]::Replace([string]$n, '[^A-Za-z0-9._-]+', '-').Trim('-', '.')
    if (-not $n) { $n = 'unknown' }
    return $n
}

function Get-BackupTarget {
    # what to back up right now: a fresh snapshot of the working tree, or (clean tree)
    # commits that never reached origin. $null = nothing unshipped on this PC.
    param($Plan, [string]$Label)
    $repo = $script:MapRepo
    if (-not $Plan) { $Plan = Get-ShipPlan }
    $snap = Save-SafetySnapshot $Plan $Label
    if ($snap) { return $snap }
    $ahead = (Run-Git $repo @('rev-list', '--count', "origin/$($script:Cfg.defaultBranch)..HEAD")).Out
    if ($ahead -match '^\d+$' -and [int]$ahead -gt 0) {
        return @{ Ref = ''; Files = 0; Commits = [int]$ahead; Sha = (Run-Git $repo @('rev-parse', 'HEAD')).Out; Tree = '' }
    }
    return $null
}

function Backup-Session {
    # Snapshot + push to GitHub, synchronously. Throws if GitHub can't take it, so the
    # caller stops: no backup, no ship. Returns $null when nothing is unshipped.
    param($Plan, [string]$Label = 'ship')
    $snap = Get-BackupTarget $Plan $Label
    if (-not $snap) { return $null }
    $remoteRef = (New-BackupRef)
    $r = Run-Git $script:MapRepo @('push', '--quiet', '--no-verify', 'origin', "$($snap.Sha):$remoteRef")
    if ($r.Code -ne 0) { throw "couldn't copy it to GitHub - internet? sign-in? ($($r.Out))" }
    $snap.Remote = $remoteRef
    try { Remove-OldBackups } catch { }
    return $snap
}

function New-BackupRef {
    # refs/backup/<owner>/<yyyyMMdd-HHmmss-fff>: the milliseconds keep two backups in the
    # same second (Workbench closed, then SHIP) from landing on one name
    return "$((Get-BackupCfg).Prefix)/$(Get-BackupOwner)/$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
}

function Remove-OldBackups {
    # keep this person's newest N on GitHub; the older ones go in one push. Best effort.
    param([int]$Keep = 0)
    if ($Keep -le 0) { $Keep = (Get-BackupCfg).Keep }
    $mine = "$((Get-BackupCfg).Prefix)/$(Get-BackupOwner)/"
    $r = Run-Git $script:MapRepo @('ls-remote', 'origin', "$mine*")
    if ($r.Code -ne 0 -or -not $r.Out) { return 0 }
    $refs = @($r.Out -split "`r?`n" | ForEach-Object { ($_ -split "`t")[-1] } | Where-Object { $_ -like "$mine*" } | Sort-Object -Descending)
    if ($refs.Count -le $Keep) { return 0 }
    $del = @($refs[$Keep..($refs.Count - 1)] | ForEach-Object { ":$_" })
    Run-Git $script:MapRepo (@('push', '--quiet', '--no-verify', 'origin') + $del) | Out-Null
    return $del.Count
}

# ------------------------------------------------------- diagnostics (v0.28)
# chazman69, 2026-11-10: "we want to see these logs from users so we can troubleshoot" -
# without asking builders to run PowerShell. Every Doctor press sends the Doctor report,
# the last few Workbench log folders and the addon folder list to GitHub as
# refs/diag/<git name>/<stamp> (a commit with no parent, like the backups: not a branch,
# never in a normal fetch). The repo is private. Keep the newest diagnostics.keepPerPerson.
# Opt out on one PC: "sendDiagnostics": false in local.json.
# Maintainer: git fetch origin "refs/diag/*:refs/diag/*", then
#   git log --all --format="%H %s" refs/diag   and   git show <sha>:doctor.txt
function Get-DiagCfg {
    $c = @{ Prefix = 'refs/diag'; Keep = 10; Sessions = 3 }
    if ($script:Cfg -and $script:Cfg.PSObject.Properties['diagnostics']) {
        $d = $script:Cfg.diagnostics
        if ($d.PSObject.Properties['remoteRefPrefix'] -and $d.remoteRefPrefix) { $c.Prefix = ([string]$d.remoteRefPrefix).TrimEnd('/') }
        if ($d.PSObject.Properties['keepPerPerson'] -and [int]$d.keepPerPerson -gt 0) { $c.Keep = [int]$d.keepPerPerson }
        if ($d.PSObject.Properties['workbenchSessions'] -and [int]$d.workbenchSessions -gt 0) { $c.Sessions = [int]$d.workbenchSessions }
    }
    return $c
}

function Get-WorkbenchLogsDir {
    return (Join-Path (Get-DocumentsDir) 'My Games\ArmaReforgerWorkbench\logs')
}

function Read-LogForDiag {
    # A log's bytes for the bundle: whole when small, else the first $Head and last $Tail
    # bytes with a marker between (engine start-up is at the top, the crash at the bottom).
    param([string]$Path, [int]$Head = 3MB, [int]$Tail = 1MB)
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($len -le ($Head + $Tail)) {
            $all = New-Object byte[] $len
            [void]$fs.Read($all, 0, [int]$len)
            return , $all
        }
        $h = New-Object byte[] $Head
        [void]$fs.Read($h, 0, $Head)
        $fs.Position = $len - $Tail
        $t = New-Object byte[] $Tail
        [void]$fs.Read($t, 0, $Tail)
        $mark = [System.Text.Encoding]::ASCII.GetBytes("`r`n`r`n----- [Foreman: $($len - $Head - $Tail) bytes cut from the middle of this log] -----`r`n`r`n")
        $out = New-Object byte[] ($Head + $mark.Length + $Tail)
        [Array]::Copy($h, 0, $out, 0, $Head)
        [Array]::Copy($mark, 0, $out, $Head, $mark.Length)
        [Array]::Copy($t, 0, $out, $Head + $mark.Length, $Tail)
        return , $out
    } finally { $fs.Dispose() }
}

function Get-AddonFolderReport {
    # One line per addon folder in every folder we know about: what Workbench (and Foreman) can see.
    $lines = @()
    $bases = @(Get-AddonBases)
    try { $wb = Find-WorkbenchExe; if ($wb) { $bases += (Join-Path (Split-Path -Parent $wb) 'addons'); $lines += "Workbench exe: $wb" } } catch { }
    foreach ($b in $bases) {
        $lines += ''
        $lines += "== $b"
        if (-not (Test-Path -LiteralPath $b)) { $lines += '   (folder does not exist)'; continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $kind = @()
            if (@(Get-ChildItem -LiteralPath $d.FullName -Filter '*.gproj' -File -ErrorAction SilentlyContinue).Count) { $kind += 'gproj' }
            if (@(Get-ChildItem -LiteralPath $d.FullName -Filter '*.pak' -File -ErrorAction SilentlyContinue).Count) { $kind += 'pak' }
            if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $kind += 'junction' }
            $lines += "   $($d.Name)  [$($kind -join ',')]"
        }
    }
    return $lines
}

function New-DiagnosticsCommit {
    # Builds the bundle as a parentless commit in the map repo (temp index, nothing in the
    # working tree or real index changes). Returns @{ Sha; Files; Logs }.
    param([string[]]$DoctorLines, [string]$LogsDir = (Get-WorkbenchLogsDir), [int]$Sessions = 0)
    if ($Sessions -le 0) { $Sessions = (Get-DiagCfg).Sessions }
    $repo = $script:MapRepo
    $tag = "$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $tmp = Join-Path $env:TEMP "foreman-diag-$tag"
    $idx = Join-Path $env:TEMP "foreman-diag-$tag.idx"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $prevIdx = $env:GIT_INDEX_FILE
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $os = ''
        try { $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | ForEach-Object { "$($_.Caption) $($_.Version)" }) } catch { $os = [Environment]::OSVersion.VersionString }
        $hdr = @("Foreman v$script:ForemanVersion", "When: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))", "Who: $(Get-BackupOwner)",
                 "Windows: $os", "PowerShell: $($PSVersionTable.PSVersion)", "Map repo: $repo", "Documents: $(Get-DocumentsDir)", '')
        [System.IO.File]::WriteAllLines((Join-Path $tmp 'doctor.txt'), [string[]]($hdr + @($DoctorLines)), $utf8)
        $addons = @()
        try { $addons = @(Get-AddonFolderReport) } catch { $addons = @("addon report failed: $($_.Exception.Message)") }
        [System.IO.File]::WriteAllLines((Join-Path $tmp 'addons.txt'), [string[]]$addons, $utf8)
        $logs = 0
        if (Test-Path -LiteralPath $LogsDir) {
            $sessionsDirs = @(Get-ChildItem -LiteralPath $LogsDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $Sessions)
            $pick = @()
            foreach ($s in $sessionsDirs) { $pick += @(Get-ChildItem -LiteralPath $s.FullName -Filter '*.log' -File -ErrorAction SilentlyContinue | ForEach-Object { @{ F = $_; Rel = "$($s.Name)\$($_.Name)" } }) }
            $pick += @(Get-ChildItem -LiteralPath $LogsDir -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $Sessions | ForEach-Object { @{ F = $_; Rel = $_.Name } })
            foreach ($p in $pick) {
                try {
                    $dest = Join-Path (Join-Path $tmp 'workbench-logs') $p.Rel
                    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
                    [System.IO.File]::WriteAllBytes($dest, (Read-LogForDiag $p.F.FullName))
                    $logs++
                } catch { }
            }
        }
        if ($logs -eq 0) { [System.IO.File]::WriteAllText((Join-Path $tmp 'workbench-logs-NONE.txt'), "No Workbench logs found in $LogsDir`r`n", $utf8) }
        $env:GIT_INDEX_FILE = $idx
        $r = Run-Git $repo @("--work-tree=$tmp", '-c', 'core.autocrlf=false', 'add', '-A', '-f', '--', ':/')
        if ($r.Code -ne 0) { throw "add: $($r.Out)" }
        $tree = (Run-Git $repo @('write-tree')).Out
        if (-not $tree) { throw 'write-tree returned nothing' }
        $files = @((Run-Git $repo @('ls-files')).Out -split "`r?`n" | Where-Object { $_ }).Count
    } finally {
        if ($prevIdx) { $env:GIT_INDEX_FILE = $prevIdx } else { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $idx, "$idx.lock" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $c = Run-Git $repo @('-c', 'user.name=BUSHWAR Foreman', '-c', 'user.email=foreman@localhost',
        'commit-tree', $tree, '-m', "Foreman diagnostics: $(Get-BackupOwner), Foreman v$script:ForemanVersion, $logs Workbench log(s)")
    if ($c.Code -ne 0 -or -not $c.Out) { throw "commit-tree: $($c.Out)" }
    return @{ Sha = $c.Out.Trim(); Files = $files; Logs = $logs }
}

function Send-Diagnostics {
    # Doctor report + Workbench logs -> GitHub. One plain-words line back; never throws.
    param([string[]]$DoctorLines)
    if ($script:Local -and $script:Local.sendDiagnostics -eq $false) {
        return '[INFO] Diagnostics not sent (turned off on this PC in local.json).'
    }
    try {
        $cfg = Get-DiagCfg
        $b = New-DiagnosticsCommit -DoctorLines $DoctorLines
        $ref = "$($cfg.Prefix)/$(Get-BackupOwner)/$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $r = Run-Git $script:MapRepo @('push', '--quiet', '--no-verify', 'origin', "$($b.Sha):$ref")
        if ($r.Code -ne 0) { return "[INFO] Couldn't send diagnostics to the team (internet? sign-in?) - screenshot this box instead. ($($r.Out))" }
        try {
            $mine = "$($cfg.Prefix)/$(Get-BackupOwner)/"
            $ls = Run-Git $script:MapRepo @('ls-remote', 'origin', "$mine*")
            $refs = @($ls.Out -split "`r?`n" | ForEach-Object { ($_ -split "`t")[-1] } | Where-Object { $_ -like "$mine*" } | Sort-Object -Descending)
            if ($refs.Count -gt $cfg.Keep) { Run-Git $script:MapRepo (@('push', '--quiet', '--no-verify', 'origin') + @($refs[$cfg.Keep..($refs.Count - 1)] | ForEach-Object { ":$_" })) | Out-Null }
        } catch { }
        return "[OK]   Sent this report and your last $($b.Logs) Workbench log file(s) to the team for troubleshooting ($ref). Nothing else to do."
    } catch {
        return "[INFO] Couldn't put together the diagnostics: $($_.Exception.Message)"
    }
}

function ConvertTo-ProcessArgs([string[]]$items) {
    # one Windows command line (ProcessStartInfo.Arguments) from an argv list
    return (@($items | ForEach-Object {
        if ($_ -eq '' -or $_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ }
    }) -join ' ')
}

function Start-GitBackground([string[]]$GitArgs) {
    # git in the background (never freezes the window); poll .HasExited, read .StandardError
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Git
    $psi.Arguments = ConvertTo-ProcessArgs (@('-C', $script:MapRepo) + @($script:CredArgs) + $GitArgs)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($psi)
}

$script:AutoBackupProc = $null
$script:AutoBackupRef = ''
$script:AutoBackupTree = ''
$script:AutoBackupFailed = $false

function Invoke-AutoBackup {
    # Timer tick (every backup.autoMinutes) and Workbench-closed: snapshot unshipped work
    # here, then copy it to GitHub in the background. Never blocks or changes anything;
    # a failed upload stays on this PC and is retried next time. Returns a one-line status.
    $p = $script:AutoBackupProc
    if ($p) {
        if (-not $p.HasExited) { return 'busy' }        # last copy still uploading
        $err = ''
        try { $err = $p.StandardError.ReadToEnd().Trim() } catch { }
        $script:AutoBackupProc = $null
        if ($p.ExitCode -eq 0) {
            $script:AutoBackupFailed = $false
            Log "[OK] Auto-backup of your unshipped work is on GitHub: $($script:AutoBackupRef)"
        } else {
            $script:AutoBackupTree = ''                     # retry the same content next time
            if (-not $script:AutoBackupFailed) {
                Log "[WARN] Auto-backup couldn't reach GitHub (internet? sign-in?). It's saved on this PC and Foreman keeps retrying. ($err)"
            }
            $script:AutoBackupFailed = $true
        }
    }
    if (-not (Run-Git $script:MapRepo @('status', '--porcelain')).Out) { return 'clean' }
    $snap = Save-SafetySnapshot (Get-ShipPlan) 'auto'
    if (-not $snap) { return 'clean' }
    if ($snap.Tree -eq $script:AutoBackupTree) {
        Run-Git $script:MapRepo @('update-ref', '-d', $snap.Ref) | Out-Null   # nothing new since the last copy
        return 'same'
    }
    $remoteRef = (New-BackupRef)
    $script:AutoBackupRef = $remoteRef
    $script:AutoBackupTree = $snap.Tree
    $script:AutoBackupProc = Start-GitBackground @('push', '--quiet', '--no-verify', 'origin', "$($snap.Sha):$remoteRef")
    return 'started'
}

# ------------------------------------------------------- prefab-loss guard (v0.25)
# INCIDENT 2026-08-19 and 2026-09-17: a Workbench that can't resolve a prefab (a
# dependency addon - usually the Fireforce props pack - is missing or OUT OF DATE on
# that machine) keeps each such entity as a bare GenericEntity/Tree at the same spot and
# drops its prefab link; classes that need prefab data (destructible walls/roofs) are
# dropped outright. The next save writes that stripped layer, the ship commits it, and the
# owner's work is empty for the whole team (22,301 plantation trees + 202 estate/station
# pieces in Malvia's layers). Nothing in LAYER GUARD noticed: it asks WHOSE file changed,
# never WHETHER objects lost their prefab, and its "ship anyway" answer let it through.
#
# In the file the damage is unmistakable: a `$grp GenericEntity {` group with no prefab,
# whose coords match entities that HAD a prefab in the committed copy. This guard reads
# exactly that - for EVERY changed layer, yours included - and offers a REPAIR that
# re-attaches the links from the committed copy (master, never anything older, so it can't
# resurrect things someone removed on purpose). There is deliberately NO ship-it-anyway.
#
# The layer files run to 60 MB, so the scan is compiled C# (PowerShell line loops take
# minutes). C# 5 only - Windows PowerShell 5.1's compiler.
$script:LayerScanSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace Bushwar
{
    // v0.27.5: file list of a packed (Workshop) addon. Workshop downloads arrive as an
    // Enfusion PAC1 archive (data.pak), not loose files, so the dependency check could
    // never see them and named every props pack "missing". Layout: "FORM" <size BE>
    // "PAC1", then chunks of <4-char id><size> (HEAD, DATA, FILE). FILE holds the tree:
    // entry = <type: 0 dir, 1 file><name length><name>, then a dir has <child count LE>
    // and its children, a file a fixed block (offset, sizes, flags, time). Only the names
    // are needed. The fixed block size and the chunk-size endianness are not hardcoded:
    // each candidate is tried and only a parse that consumes the FILE chunk EXACTLY,
    // with sane names, is accepted - anything else throws, and Doctor then says it
    // couldn't check instead of crying "missing".
    public static class PakIndex
    {
        static readonly int[] FileBlockSizes = { 24, 20, 28, 16, 32 };

        static uint BE(byte[] b, int o) { return (uint)((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]); }
        static uint LE(byte[] b, int o) { return (uint)(b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)); }

        static int ReadFull(Stream s, byte[] buf, int n)
        {
            int got = 0;
            while (got < n) { int r = s.Read(buf, got, n - got); if (r <= 0) break; got += r; }
            return got;
        }

        static bool IsChunkId(byte[] b)
        {
            for (int k = 0; k < 4; k++) { byte c = b[k]; if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return false; }
            return true;
        }

        // Addon-relative paths ("Commercial/Prefabs/x.et") of every file in the pak.
        public static List<string> Files(string path)
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                long len = fs.Length;
                byte[] h = new byte[12];
                if (ReadFull(fs, h, 12) != 12) throw new InvalidDataException("file too short");
                if (Encoding.ASCII.GetString(h, 0, 4) != "FORM" || Encoding.ASCII.GetString(h, 8, 4) != "PAC1")
                    throw new InvalidDataException("not an Enfusion PAC1 pak");
                long pos = 12;
                byte[] ch = new byte[8];
                bool retried = false;
                while (pos + 8 <= len)
                {
                    fs.Position = pos;
                    if (ReadFull(fs, ch, 8) != 8) break;
                    if (!IsChunkId(ch))
                    {
                        if (retried) throw new InvalidDataException("lost chunk alignment at byte " + pos);
                        retried = true; pos++; continue;      // IFF-style pad byte after an odd chunk
                    }
                    retried = false;
                    string id = Encoding.ASCII.GetString(ch, 0, 4);
                    long rem = len - pos - 8;
                    long size = BE(ch, 4);
                    if (size > rem)
                    {
                        long le = LE(ch, 4);
                        if (le > rem) throw new InvalidDataException("chunk " + id + " runs past the end of the file");
                        size = le;
                    }
                    if (id == "FILE")
                    {
                        if (size > 512L * 1024 * 1024) throw new InvalidDataException("FILE chunk implausibly large");
                        byte[] t = new byte[size];
                        if (ReadFull(fs, t, (int)size) != size) throw new InvalidDataException("FILE chunk truncated");
                        return ParseTree(t);
                    }
                    pos += 8 + size;
                }
                throw new InvalidDataException("no FILE chunk found");
            }
        }

        public static List<string> ParseTree(byte[] t)
        {
            foreach (int fsz in FileBlockSizes)
            {
                // a) one root directory holding everything
                List<string> a = new List<string>();
                int p = 0;
                if (t.Length > 0 && t[0] == 0 && Entry(t, ref p, fsz, "", a, 0) && p == t.Length && a.Count > 0) return a;
                // b) a flat run of top-level entries
                List<string> b = new List<string>();
                p = 0;
                bool ok = true;
                while (p < t.Length) { if (!Entry(t, ref p, fsz, "", b, 1)) { ok = false; break; } }
                if (ok && p == t.Length && b.Count > 0) return b;
            }
            throw new InvalidDataException("unrecognised FILE table layout");
        }

        static bool Entry(byte[] t, ref int p, int fsz, string prefix, List<string> outp, int depth)
        {
            if (depth > 64 || p + 2 > t.Length) return false;
            byte type = t[p];
            int nl = t[p + 1];
            p += 2;
            if (type > 1 || p + nl > t.Length) return false;
            for (int k = 0; k < nl; k++) { byte c = t[p + k]; if (c < 0x20 || c == (byte)'/' || c == (byte)'\\') return false; }
            string name = Encoding.UTF8.GetString(t, p, nl);
            p += nl;
            if (type == 0)
            {
                if (nl == 0 && depth > 0) return false;           // only the root may be unnamed
                if (p + 4 > t.Length) return false;
                uint n = LE(t, p);
                p += 4;
                if (n > (uint)(t.Length - p) / 2) return false;
                string pre = depth == 0 ? "" : prefix + name + "/";  // the root's own name is not part of the path
                for (uint i = 0; i < n; i++) if (!Entry(t, ref p, fsz, pre, outp, depth + 1)) return false;
                return true;
            }
            if (nl == 0 || p + fsz > t.Length) return false;
            p += fsz;
            outp.Add(prefix + name);
            return true;
        }
    }

    public sealed class LayerScanInfo
    {
        public List<string> BareCoords = new List<string>();
        public List<bool> BareMeshed = new List<bool>();          // parallel to BareCoords: the instance carries its own MeshObject mesh
        public Dictionary<string, string> Prefabbed = new Dictionary<string, string>();
        public HashSet<string> Ambiguous = new HashSet<string>();
        public HashSet<string> Singles = new HashSet<string>();   // keys whose committed form is a lone `Class : "{GUID}path" {` block
        public int PrefabbedCount;
    }

    public sealed class PrefabLossResult
    {
        public int Stripped;   // bare entities whose exact coords carried a prefab in the committed layer
        public int NewBare;    // bare entities that match nothing in the committed layer (and have no mesh of their own)
        public int NewMeshed;  // new prefab-less entities built from a raw .xob - deliberate, not empty
        public int Missing;    // committed prefabbed entities absent from the working layer, beyond the stripped ones
        public Dictionary<string, int> ByPrefab = new Dictionary<string, int>();
    }

    public static class LayerScan
    {
        static readonly Regex BareHdr = new Regex(@"^\$grp (GenericEntity|Tree)( \w+)? \{$", RegexOptions.Compiled);
        static readonly Regex PrefabPath = new Regex("\"\\{[0-9A-Fa-f]{16}\\}([^\"]+)\"", RegexOptions.Compiled);
        static readonly Regex RefRe = new Regex("\"\\{([0-9A-Fa-f]{16})\\}([^\"\\r\\n]+)\"", RegexOptions.Compiled);
        const string CoordsPrefix = "  coords ";          // instance inside a $grp group (2-space indent, 9 chars)
        const string SingleCoordsPrefix = " coords ";      // lone entity block (1-space indent, 8 chars)
        const string MeshCompPrefix = "   MeshObject ";    // the instance's own MeshObject component (3-space indent)
        const string MeshObjPrefix = "    Object \"";      // its mesh: `Object "{GUID}path.xob"` (4-space indent)

        static bool IsHeaderStart(char c) { return c != ' ' && c != '\t' && c != '}'; }

        static string PrefabName(string hdr)
        {
            Match m = PrefabPath.Match(hdr);
            return m.Success ? m.Groups[1].Value : hdr;
        }

        // One pass over the layer text. An entity's position is its `coords` line: 2-space
        // indented inside a top-level `$grp` group (deeper-indented lines are nested children),
        // or 1-space indented in a lone top-level `Class : "{GUID}path" {` block.
        //
        // v0.26.2: a bare instance is not necessarily EMPTY. Builders place raw meshes as a
        // prefab-less GenericEntity with its own `MeshObject { Object "...xob" }` (Malvia's
        // modular walls and office windows, Joe's doors). Workbench's stripped entities never
        // carry one - they are coords/angles only - so the mesh is what tells the two apart.
        public static LayerScanInfo Scan(string text, bool wantMap)
        {
            LayerScanInfo info = new LayerScanInfo();
            int mode = 0;            // 0 = other, 1 = bare $grp group, 2 = prefabbed $grp group, 3 = lone prefabbed block
            string hdr = null;
            bool inMesh = false, instMesh = false;   // bare-group instance: inside its MeshObject / has a mesh
            int instIdx = -1;                        // its BareCoords index once its coords are seen
            int pos = 0, n = text.Length;
            while (pos < n)
            {
                int nl = text.IndexOf('\n', pos);
                int end = nl < 0 ? n : nl;
                int len = end - pos;
                if (len > 0 && text[end - 1] == '\r') len--;
                if (len > 0)
                {
                    if (IsHeaderStart(text[pos]))
                    {
                        string line = text.Substring(pos, len);
                        if (BareHdr.IsMatch(line)) { mode = 1; hdr = line; }
                        else if (line.IndexOf(": \"{", StringComparison.Ordinal) > 0)
                        {
                            mode = line.StartsWith("$grp ", StringComparison.Ordinal) ? 2 : 3;
                            hdr = line;
                        }
                        else { mode = 0; hdr = null; }
                        inMesh = false; instMesh = false; instIdx = -1;
                    }
                    else if (mode != 0)
                    {
                        if (mode == 1)
                        {
                            if (len == 2 && text[pos + 1] == '{') { inMesh = false; instMesh = false; instIdx = -1; }   // ` {` = next instance
                            else if (len > 3 && string.CompareOrdinal(text, pos, "   ", 0, 3) == 0 && text[pos + 3] != ' ')
                                inMesh = len > 14 && string.CompareOrdinal(text, pos, MeshCompPrefix, 0, 14) == 0;
                            else if (inMesh && len > 12 && string.CompareOrdinal(text, pos, MeshObjPrefix, 0, 12) == 0)
                            {
                                instMesh = true;
                                if (instIdx >= 0) info.BareMeshed[instIdx] = true;   // the mesh came after the coords
                            }
                        }
                        int pre = mode == 3 ? 8 : 9;
                        string prefix = mode == 3 ? SingleCoordsPrefix : CoordsPrefix;
                        if (len > pre && string.CompareOrdinal(text, pos, prefix, 0, pre) == 0 && text[pos + pre] != ' ')
                        {
                            if (mode == 1)
                            {
                                info.BareCoords.Add(text.Substring(pos + pre, len - pre).TrimEnd());
                                info.BareMeshed.Add(instMesh);
                                instIdx = info.BareCoords.Count - 1;
                            }
                            else
                            {
                                info.PrefabbedCount++;
                                if (wantMap)
                                {
                                    string key = text.Substring(pos + pre, len - pre).TrimEnd();
                                    string prev;
                                    if (info.Prefabbed.TryGetValue(key, out prev)) { if (prev != hdr) info.Ambiguous.Add(key); }
                                    else
                                    {
                                        info.Prefabbed[key] = hdr;
                                        if (mode == 3) info.Singles.Add(key);
                                    }
                                }
                            }
                        }
                    }
                }
                pos = end + 1;
            }
            return info;
        }

        // work = the layer as it sits in the working tree; head = the committed (master) copy.
        public static PrefabLossResult Analyze(string work, string head)
        {
            PrefabLossResult r = new PrefabLossResult();
            LayerScanInfo w = Scan(work, false);
            if (w.BareCoords.Count == 0) return r;              // nothing bare -> nothing stripped (cheap exit)
            LayerScanInfo h = Scan(head, true);
            HashSet<string> headBare = new HashSet<string>(h.BareCoords);
            for (int i = 0; i < w.BareCoords.Count; i++)
            {
                string c = w.BareCoords[i];
                string hdr;
                // a match on coords is still a strip, mesh or not - only NEW entities get the mesh pass
                if (h.Prefabbed.TryGetValue(c, out hdr))
                {
                    r.Stripped++;
                    string name = PrefabName(hdr);
                    int k;
                    r.ByPrefab.TryGetValue(name, out k);
                    r.ByPrefab[name] = k + 1;
                }
                else if (!headBare.Contains(c))
                {
                    if (w.BareMeshed[i]) r.NewMeshed++;
                    else r.NewBare++;
                }
            }
            if (r.Stripped > 0)
            {
                int miss = h.PrefabbedCount - w.PrefabbedCount - r.Stripped;
                r.Missing = miss > 0 ? miss : 0;
            }
            return r;
        }

        static void Emit(StringBuilder sb, string line, ref bool first)
        {
            if (!first) sb.Append('\n');
            sb.Append(line);
            first = false;
        }

        static void EmitGroup(StringBuilder sb, string hdr, List<List<string>> insts, ref bool first)
        {
            Emit(sb, hdr, ref first);
            foreach (List<string> inst in insts) foreach (string l in inst) Emit(sb, l, ref first);
            Emit(sb, "}", ref first);
        }

        // Re-attach the prefab header to every bare entity whose exact coords carry one in `head`.
        // Everything else - instance text, other groups, line endings - is copied through untouched.
        public static string Restore(string work, string head, out int restored)
        {
            restored = 0;
            bool crlf = work.IndexOf("\r\n", StringComparison.Ordinal) >= 0;
            string w = crlf ? work.Replace("\r\n", "\n") : work;
            string hd = head.IndexOf('\r') >= 0 ? head.Replace("\r\n", "\n") : head;
            LayerScanInfo h = Scan(hd, true);
            string[] lines = w.Split('\n');
            StringBuilder sb = new StringBuilder(w.Length + 4096);
            bool first = true;
            int i = 0;
            while (i < lines.Length)
            {
                string line = lines[i];
                bool isBare = line.Length > 0 && line.StartsWith("$grp ", StringComparison.Ordinal) && BareHdr.IsMatch(line);
                if (!isBare) { Emit(sb, line, ref first); i++; continue; }

                int j = i + 1;                                   // the block runs to the next header line
                while (j < lines.Length && !(lines[j].Length > 0 && IsHeaderStart(lines[j][0]))) j++;

                List<List<string>> insts = new List<List<string>>();
                List<string> cur = null;
                List<string> tail = new List<string>();
                bool odd = false;
                for (int k = i + 1; k < j; k++)
                {
                    string ln = lines[k];
                    if (cur == null)
                    {
                        if (ln == " {") { cur = new List<string>(); cur.Add(ln); }
                        else if (ln == "}" || ln.Length == 0) tail.Add(ln);
                        else { odd = true; break; }
                    }
                    else
                    {
                        cur.Add(ln);
                        if (ln == " }") { insts.Add(cur); cur = null; }
                    }
                }
                if (cur != null) odd = true;
                if (odd) { for (int k = i; k < j; k++) Emit(sb, lines[k], ref first); i = j; continue; }

                List<string> order = new List<string>();
                Dictionary<string, List<List<string>>> groups = new Dictionary<string, List<List<string>>>();
                List<KeyValuePair<string, List<string>>> singles = new List<KeyValuePair<string, List<string>>>();
                List<List<string>> leftover = new List<List<string>>();
                foreach (List<string> inst in insts)
                {
                    string key = null;
                    foreach (string il in inst)
                    {
                        if (il.Length > 9 && string.CompareOrdinal(il, 0, CoordsPrefix, 0, 9) == 0 && il[9] != ' ')
                        {
                            key = il.Substring(9).TrimEnd();
                            break;
                        }
                    }
                    string phdr;
                    if (key != null && !h.Ambiguous.Contains(key) && h.Prefabbed.TryGetValue(key, out phdr))
                    {
                        if (h.Singles.Contains(key))
                        {
                            // it was a lone `Class : "{GUID}path" {` block; Workbench folded it into the bare group
                            singles.Add(new KeyValuePair<string, List<string>>(phdr, inst));
                        }
                        else
                        {
                            List<List<string>> g;
                            if (!groups.TryGetValue(phdr, out g)) { g = new List<List<string>>(); groups[phdr] = g; order.Add(phdr); }
                            g.Add(inst);
                        }
                        restored++;
                    }
                    else leftover.Add(inst);
                }

                // the block's own closing '}' is re-emitted per group; whatever follows it (a blank
                // line when this is the file's last block) is emitted once, after the last piece.
                List<string> extraTail = tail.Count > 1 ? tail.GetRange(1, tail.Count - 1) : new List<string>();
                int pieces = order.Count + singles.Count + (leftover.Count > 0 ? 1 : 0);
                int done = 0;
                foreach (string ph in order)
                {
                    EmitGroup(sb, ph, groups[ph], ref first);
                    done++;
                    if (done == pieces) foreach (string t in extraTail) Emit(sb, t, ref first);
                }
                foreach (KeyValuePair<string, List<string>> s in singles)
                {
                    // back to the lone-block form: header, the instance body one indent level shallower, '}'
                    Emit(sb, s.Key, ref first);
                    for (int k = 1; k < s.Value.Count - 1; k++)
                        Emit(sb, s.Value[k].Length > 0 && s.Value[k][0] == ' ' ? s.Value[k].Substring(1) : s.Value[k], ref first);
                    Emit(sb, "}", ref first);
                    done++;
                    if (done == pieces) foreach (string t in extraTail) Emit(sb, t, ref first);
                }
                if (leftover.Count > 0)
                {
                    EmitGroup(sb, line, leftover, ref first);
                    foreach (string t in extraTail) Emit(sb, t, ref first);
                }
                i = j;
            }
            string result = sb.ToString();
            return crlf ? result.Replace("\n", "\r\n") : result;
        }

        // Every `"{GUID}path"` reference in a layer, as "GUID|path" (for the dependency check).
        public static HashSet<string> PrefabRefs(string text)
        {
            HashSet<string> set = new HashSet<string>();
            foreach (Match m in RefRe.Matches(text))
                set.Add(m.Groups[1].Value.ToUpperInvariant() + "|" + m.Groups[2].Value);
            return set;
        }
    }

    // v0.26: "is this layer save a pure re-save?" by CONTENT, not by entity count.
    // The old count test (v0.21) called a session churn whenever the number of `coords`
    // lines matched HEAD - but moving a road's spline points, nudging a building or
    // rotating a tree keeps the count, so real edits were silently reverted at ship
    // (Joe's Mike's-side road fixes, 2026-10-18). Here every entity becomes one record
    // (class | prefab | name + its normalised body), independent of how Workbench groups
    // the file ($grp blocks vs lone blocks) or orders it; numbers are compared to 1 mm /
    // 0.001 deg. Equal record sets = same world = safe to drop. Anything else is a real
    // edit and ships. Any doubt (parse trouble) answers "not the same".
    public static class LayerCanon
    {
        static readonly char[] Space = new char[] { ' ' };

        // trim, single spaces, and every whitespace-separated decimal number rounded to 0.001
        // (so Workbench's float jitter on re-save compares equal). Tokens that aren't plain
        // numbers - names, "{GUID}path" - are kept exactly.
        static string Norm(string line)
        {
            string t = line.Trim();
            if (t.IndexOf("  ", StringComparison.Ordinal) >= 0 || t.IndexOf('\t') >= 0)
                t = string.Join(" ", t.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries));
            if (t.IndexOf('.') < 0) return t;
            string[] parts = t.Split(Space);
            bool changed = false;
            for (int k = 0; k < parts.Length; k++)
            {
                string w = parts[k];
                if (w.IndexOf('.') < 0) continue;
                char c0 = w[0];
                if (!(char.IsDigit(c0) || c0 == '-' || c0 == '.')) continue;
                double v;
                if (!double.TryParse(w, System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out v)) continue;
                v = Math.Round(v, 3);
                if (v == 0) v = 0;   // no "-0"
                parts[k] = v.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
                changed = true;
            }
            return changed ? string.Join(" ", parts) : t;
        }

        static int Depth(string t)
        {
            int d = 0;
            for (int k = 0; k < t.Length; k++) { if (t[k] == '{') d++; else if (t[k] == '}') d--; }
            return d;
        }

        // "Class Name : \"{GUID}path\"" -> class, name, prefab (any part may be empty)
        static void SplitHeader(string h, out string cls, out string name, out string prefab)
        {
            prefab = "";
            int c = h.IndexOf(" : \"", StringComparison.Ordinal);
            if (c >= 0) { prefab = h.Substring(c + 3).Trim(); h = h.Substring(0, c); }
            h = h.Trim();
            int s = h.IndexOf(' ');
            if (s < 0) { cls = h; name = ""; }
            else { cls = h.Substring(0, s); name = h.Substring(s + 1).Trim(); }
        }

        // body lines of a block whose header was lines[i-1]; returns the index after its closing line
        static int Body(string[] lines, int i, StringBuilder sb)
        {
            int depth = 1;
            while (i < lines.Length && depth > 0)
            {
                string t = lines[i].Trim();
                depth += Depth(t);
                if (depth > 0 && t.Length > 0) sb.Append('\n').Append(Norm(t));
                i++;
            }
            return i;
        }

        public static List<string> Records(string text)
        {
            List<string> recs = new List<string>();
            string[] lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
            int i = 0;
            while (i < lines.Length)
            {
                string raw = lines[i];
                string t = raw.Trim();
                if (t.Length == 0) { i++; continue; }
                bool top = raw[0] != ' ' && raw[0] != '\t';
                if (!(top && t.EndsWith("{")))
                {
                    recs.Add("?|" + Norm(t));
                    i++;
                    continue;
                }
                string hdr = t.Substring(0, t.Length - 1).Trim();
                string cls, name, prefab;
                if (hdr.StartsWith("$grp "))
                {
                    SplitHeader(hdr.Substring(5), out cls, out name, out prefab);
                    i++;
                    while (i < lines.Length)
                    {
                        string r2 = lines[i];
                        string t2 = r2.Trim();
                        if (t2.Length == 0) { i++; continue; }
                        if (t2 == "}" && r2[0] == '}') { i++; break; }   // end of the group
                        if (t2.EndsWith("{"))
                        {
                            StringBuilder sb = new StringBuilder();
                            sb.Append(cls).Append('|').Append(prefab).Append('|').Append(t2.Substring(0, t2.Length - 1).Trim());
                            i = Body(lines, i + 1, sb);
                            recs.Add(sb.ToString());
                        }
                        else { recs.Add("?grp|" + cls + "|" + Norm(t2)); i++; }
                    }
                }
                else
                {
                    SplitHeader(hdr, out cls, out name, out prefab);
                    StringBuilder sb = new StringBuilder();
                    sb.Append(cls).Append('|').Append(prefab).Append('|').Append(name);
                    i = Body(lines, i + 1, sb);
                    recs.Add(sb.ToString());
                }
            }
            recs.Sort(StringComparer.Ordinal);
            return recs;
        }

        // Fast pass: same lines in the same order, each equal after Norm (CRLF or LF either
        // side). Walks both texts in place - no copies - so a re-save of even the 87 MB
        // vegetation layer is settled in well under a second.
        static bool SameLines(string a, string b)
        {
            int ia = 0, ib = 0;
            while (true)
            {
                bool endA = ia >= a.Length, endB = ib >= b.Length;
                if (endA || endB) return endA && endB;
                int ea = a.IndexOf('\n', ia); if (ea < 0) ea = a.Length;
                int eb = b.IndexOf('\n', ib); if (eb < 0) eb = b.Length;
                int la = ea - ia; if (la > 0 && a[ea - 1] == '\r') la--;
                int lb = eb - ib; if (lb > 0 && b[eb - 1] == '\r') lb--;
                if (!(la == lb && string.CompareOrdinal(a, ia, b, ib, la) == 0))
                {
                    if (!string.Equals(Norm(a.Substring(ia, la)), Norm(b.Substring(ib, lb)), StringComparison.Ordinal)) return false;
                }
                ia = ea + 1; ib = eb + 1;
            }
        }

        // Regroup-tolerant compare (record sets) only below this size: above it, a layer
        // Workbench re-ordered is reported "not the same" and simply ships - never dropped.
        public static int FullCompareMaxChars = 24000000;

        public static bool SameContent(string a, string b)
        {
            if (a == null || b == null) return false;
            if (string.Equals(a, b, StringComparison.Ordinal)) return true;
            try
            {
                if (SameLines(a, b)) return true;
                if (a.Length > FullCompareMaxChars || b.Length > FullCompareMaxChars) return false;
                List<string> ra = Records(a);
                List<string> rb = Records(b);
                if (ra.Count != rb.Count) return false;
                for (int k = 0; k < ra.Count; k++)
                    if (!string.Equals(ra[k], rb[k], StringComparison.Ordinal)) return false;
                return true;
            }
            catch (Exception) { return false; }
        }
    }
}
'@

function Initialize-LayerScan {
    if (-not ('Bushwar.LayerScan' -as [type])) {
        Add-Type -TypeDefinition $script:LayerScanSource -Language CSharp
    }
}

function Get-PrefabGuardCfg {
    # foreman.config.json "prefabGuard" block, with safe defaults for a framework seed without one.
    $c = @{
        layersFolder      = 'map/Worlds/GrandReef/GrandReef_Layers'
        minUnmatchedBare  = 10
        baseGameRoots     = @('Prefabs', 'PrefabLibrary', 'PrefabsEditable', 'Assets', 'Configs', 'Sounds', 'UI', 'Common', 'Worlds', 'Terrains', 'Scripts', 'Materials', 'Textures', 'Particles', 'Characters', 'Language')
        extraAddonFolders = @()
        ignoreRoots       = @()
    }
    if ($script:Cfg.PSObject.Properties['prefabGuard']) {
        $g = $script:Cfg.prefabGuard
        foreach ($k in @($c.Keys)) { if ($g.PSObject.Properties[$k]) { $c[$k] = $g.$k } }
    }
    return $c
}

function Read-GitText([string]$rev, [string]$rel) {
    # Exact `git show <rev>:<path>` as a string, or $null when the path isn't in that revision.
    # Run-Git pipes through Out-String, which is far too slow for a 60 MB layer.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Git
    $psi.Arguments = "-C `"$($script:MapRepo)`" show ${rev}:$rel"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $text = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { return $null }
    return $text
}

function Get-PrefabLoss {
    # Every changed .layer (any owner) that lost prefab links vs the committed copy.
    # A brand-new layer has no committed copy, so there is nothing to compare against.
    param($Plan)
    Initialize-LayerScan
    $cfg = Get-PrefabGuardCfg
    $found = @()
    if (-not $script:Cfg.PSObject.Properties['layers']) { return $found }
    foreach ($p in @($Plan.Other)) {
        if (-not [regex]::IsMatch($p, $script:Cfg.layers.layerFileRegex)) { continue }
        $full = Join-Path $script:MapRepo $p
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $head = Read-GitText 'HEAD' $p
        if ($null -eq $head) { continue }
        $work = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
        $r = [Bushwar.LayerScan]::Analyze($work, $head)
        if ($r.Stripped -gt 0 -or $r.NewBare -ge [int]$cfg.minUnmatchedBare) {
            $top = @($r.ByPrefab.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 |
                ForEach-Object { "$($_.Value) x $($_.Key)" })
            $found += , @{
                Path = $p; Stripped = $r.Stripped; NewBare = $r.NewBare; Missing = $r.Missing; Top = $top
                Repairable = ($r.NewBare -lt [int]$cfg.minUnmatchedBare)
            }
        }
    }
    return $found
}

function Invoke-PrefabRepair([string]$rel) {
    # Re-attach the prefab links from the committed copy. Returns how many were restored.
    Initialize-LayerScan
    $full = Join-Path $script:MapRepo $rel
    $head = Read-GitText 'HEAD' $rel
    if ($null -eq $head) { throw "No committed copy of $rel to repair from." }
    $work = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    $restored = 0
    $fixed = [Bushwar.LayerScan]::Restore($work, $head, [ref]$restored)
    # never write a repair we can't prove: it must leave nothing stripped and lose no entities
    $after = [Bushwar.LayerScan]::Analyze($fixed, $head)
    if ($after.Stripped -ne 0) { throw "Repair of $rel did not clear the stripped entities - left untouched." }
    [System.IO.File]::WriteAllText($full, $fixed, (New-Object System.Text.UTF8Encoding($false)))
    return $restored
}

function Confirm-PrefabGuard {
    # Runs BEFORE the layer guard, on every changed layer. Returns @{ Proceed; Replan; Notes }.
    param($Plan)
    $out = @{ Proceed = $true; Replan = $false; Notes = @() }
    $loss = @(Get-PrefabLoss $Plan)
    if ($loss.Count -eq 0) { return $out }

    $fixable = (@($loss | Where-Object { -not $_.Repairable }).Count -eq 0)
    $anyMissing = (@($loss | Where-Object { $_.Missing -gt 0 }).Count -gt 0)
    $lines = @()
    foreach ($l in $loss) {
        $what = "$($l.Stripped) object(s) lost their prefab"
        if ($l.NewBare -gt 0) { $what += ", $($l.NewBare) new empty object(s)" }
        $lines += '    ' + (Split-Path $l.Path -Leaf) + '  -  ' + $what
        foreach ($t in $l.Top) { $lines += '        e.g. ' + $t }
        if ($l.Missing -gt 0) { $lines += "        + about $($l.Missing) more are missing outright (the engine drops some kinds, e.g. destructible walls/roofs)" }
    }
    $head = "PREFAB LOSS - this session would ship EMPTY objects.`n`n" +
        "Workbench couldn't find some prefabs, so it stripped them from these layers - each object is still there, but as an invisible empty entity:`n`n" +
        ($lines -join "`n") + "`n`n" +
        "CAUSE: an addon this map depends on (usually the Fireforce props pack) is missing or OUT OF DATE on THIS computer. Shipping it would wipe those objects for the WHOLE team - it's how the plantation and the station were lost on 08/19 and 09/17.`n`n" +
        "FIX IT AT THE SOURCE: run Doctor (it names the missing prefabs), update that addon, then START SESSION.`n`n"
    if ($fixable) {
        $msg = $head + "Foreman can still save this session:`n" +
            "YES    =  REPAIR - put the prefab links back from the team's copy on master, keep all your other edits, and ship (backup of your files kept)`n" +
            "NO     =  DISCARD my changes to those layers (backup kept) and ship the rest`n" +
            "CANCEL =  stop, ship nothing"
        if ($anyMissing) { $msg += "`n`nNOTE: some objects are missing outright and REPAIR can't bring those back - pick NO to keep the team's complete copy." }
        $mb = [System.Windows.Forms.MessageBox]::Show($msg, 'BUSHWAR Foreman - PREFAB LOSS',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Stop,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button3)
        $doRepair = ($mb -eq [System.Windows.Forms.DialogResult]::Yes)
        $doDiscard = ($mb -eq [System.Windows.Forms.DialogResult]::No)
    } else {
        $msg = $head + "Some of these are NEW objects placed while the addon was missing - they can't be repaired.`n" +
            "YES  =  DISCARD my changes to those layers (backup kept) and ship the rest`n" +
            "NO   =  stop, ship nothing"
        $mb = [System.Windows.Forms.MessageBox]::Show($msg, 'BUSHWAR Foreman - PREFAB LOSS',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Stop,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        $doRepair = $false
        $doDiscard = ($mb -eq [System.Windows.Forms.DialogResult]::Yes)
    }

    if (-not $doRepair -and -not $doDiscard) {
        $out.Proceed = $false
        $out.Notes += '[STOP] Ship cancelled by the prefab guard - nothing was changed. Update the missing addon (Doctor lists it), START SESSION, then ship again.'
        return $out
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bdir = Join-Path $env:LOCALAPPDATA "BushwarForeman\layer-backups\$stamp"
    New-Item -ItemType Directory -Force -Path $bdir | Out-Null
    foreach ($l in $loss) {
        $full = Join-Path $script:MapRepo $l.Path
        Copy-Item -LiteralPath $full (Join-Path $bdir (Split-Path $l.Path -Leaf)) -Force
        if ($doRepair) {
            $n = Invoke-PrefabRepair $l.Path
            $out.Notes += "[FIX] repaired $(Split-Path $l.Path -Leaf): re-attached $n prefab link(s) from the team's copy."
        } else {
            $r = Run-Git $script:MapRepo @('checkout', '--', $l.Path)
            if ($r.Code -ne 0) { throw "Couldn't restore $($l.Path) from master: $($r.Out)" }
            $out.Notes += "[FIX] discarded your changes to $(Split-Path $l.Path -Leaf) (the team's copy is back)."
        }
    }
    $out.Notes += "[OK] backup of the layer file(s) as they were: $bdir"
    $out.Replan = $true
    return $out
}

# ---- dependency check (v0.25): do the prefabs the layers use actually exist on THIS machine?
# The ship guard above is the safety net; this is the early warning. It lists prefab paths
# the layers reference that aren't in any addon folder Foreman can see, grouped by the
# folder they'd live in (ModularStructurePieces, Agricultural, ...), so a stale or missing
# props pack is named BEFORE anyone opens Workbench. Base-game paths (Prefabs/, Assets/...)
# can't be checked from disk and are skipped. Warning only - a false alarm must never block
# a builder. Workshop installs are packed (.pak): v0.27.5 reads their file tables
# (Bushwar.PakIndex), and a pack it can't read turns the result into [INFO], not [WARN].

function Get-AddonBases {
    # Every addons folder we know about: Workbench's, the game client's (where Workshop
    # downloads land), plus any extraAddonFolders from the config.
    $bases = @((Get-AddonsRoot), (Join-Path (Get-DocumentsDir) 'My Games\ArmaReforger\addons'))
    foreach ($x in @((Get-PrefabGuardCfg).extraAddonFolders)) {
        if ($x) { $bases += [Environment]::ExpandEnvironmentVariables([string]$x) }
    }
    return @($bases | Select-Object -Unique)
}

function Get-PackedAddonFiles {
    # v0.27.5: Workshop addons are packed (.pak), so their prefabs aren't loose files a
    # Test-Path can see. Read each pak's file table instead.
    # Returns @{ Known = case-insensitive set of addon-relative paths; Read = paks read;
    #            Failed = @("Addon\data.pak: why") }.
    param([string[]]$Bases)
    Initialize-LayerScan
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $read = 0; $failed = @()
    foreach ($b in $Bases) {
        if (-not (Test-Path -LiteralPath $b)) { continue }
        foreach ($p in @(Get-ChildItem -LiteralPath $b -Filter '*.pak' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
            try {
                foreach ($f in [Bushwar.PakIndex]::Files($p.FullName)) { [void]$known.Add($f) }
                $read++
            } catch {
                $e = $_.Exception
                if ($e.InnerException) { $e = $e.InnerException }
                $failed += "$(Split-Path (Split-Path $p.FullName -Parent) -Leaf)\$($p.Name): $($e.Message)"
            }
        }
    }
    return @{ Known = $known; Read = $read; Failed = $failed }
}

function Get-AddonContentRoots {
    # Content roots = folders holding a *.gproj, under every addons folder we know about,
    # plus the map's own map/ folder. (Some packs name their project file addon.gproj,
    # most name it after themselves - so match any *.gproj.)
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($b in (Get-AddonBases)) {
        if (-not (Test-Path -LiteralPath $b)) { continue }
        $dirs = @(Get-Item -LiteralPath $b) + @(Get-ChildItem -LiteralPath $b -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            if (@(Get-ChildItem -LiteralPath $d.FullName -Filter '*.gproj' -File -ErrorAction SilentlyContinue).Count -gt 0) { $roots.Add($d.FullName) }
        }
    }
    $map = Join-Path $script:MapRepo 'map'
    if (Test-Path -LiteralPath $map) { $roots.Add($map) }
    return @($roots.ToArray() | Select-Object -Unique)
}

function Get-MapDependencyGuids {
    # The GUIDs in the map's addon.gproj Dependencies block.
    $gp = Join-Path $script:MapRepo 'map\addon.gproj'
    if (-not (Test-Path -LiteralPath $gp)) { return @() }
    $text = [System.IO.File]::ReadAllText($gp)
    $m = [regex]::Match($text, '(?s)Dependencies\s*\{(.*?)\}')
    if (-not $m.Success) { return @() }
    return @([regex]::Matches($m.Groups[1].Value, '"([0-9A-Fa-f]{16})"') | ForEach-Object { $_.Groups[1].Value.ToUpper() } | Select-Object -Unique)
}

function Get-InstalledAddonGuids {
    # Every addon GUID on this PC: a loose addon's own GUID line in its .gproj, or a
    # Workshop download's folder name, which ends in _<GUID> (e.g. RuralGairezi_802322404D3C21FB).
    param([string[]]$Bases)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($b in $Bases) {
        if (-not $b -or -not (Test-Path -LiteralPath $b)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $b -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue)) {
            if ($d.Name -match '_([0-9A-Fa-f]{16})$') { [void]$set.Add($Matches[1]) }
        }
        foreach ($g in @(Get-ChildItem -LiteralPath $b -Filter '*.gproj' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
            try {
                $m = [regex]::Match([System.IO.File]::ReadAllText($g.FullName), '(?m)^\s*GUID\s+"([0-9A-Fa-f]{16})"')
                if ($m.Success) { [void]$set.Add($m.Groups[1].Value) }
            } catch { }
        }
    }
    return ,$set
}

function Find-MissingDependencies {
    # Pure so it can be smoke-tested: dependency GUIDs not installed, base game excluded
    # (it lives inside Tools in a layout that varies - see Test-BaseGameLaunchFailed).
    param([string[]]$Needed, $Installed)
    return @($Needed | Where-Object { $_ -and $_ -ne $script:BaseGameGuid -and -not $Installed.Contains($_) })
}

function Get-DependencyNames {
    # GUID -> addon name from the map repo's map/ADDON.md table (team-maintained).
    $names = @{}
    $md = Join-Path $script:MapRepo 'map\ADDON.md'
    if (Test-Path -LiteralPath $md) {
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($md, [System.Text.Encoding]::UTF8), '(?m)^\|\s*`([0-9A-Fa-f]{16})`\s*\|\s*([^|\r\n]+?)\s*\|')) {
            $names[$m.Groups[1].Value.ToUpper()] = ($m.Groups[2].Value -replace '\s*\*\(.*?\)\*', '').Trim()
        }
    }
    return $names
}

function Get-MissingDependencyLines {
    # v0.27.7: name the map dependencies this PC doesn't have. Workbench can't start the
    # map without them ("Can't initialize engine"), which is what a new builder hits first.
    $need = @(Get-MapDependencyGuids)
    if ($need.Count -eq 0) { return @() }
    $have = Get-InstalledAddonGuids -Bases (Get-AddonBases)
    $miss = @(Find-MissingDependencies -Needed $need -Installed $have)
    $n = @($need | Where-Object { $_ -ne $script:BaseGameGuid }).Count
    if ($miss.Count -eq 0) { return @("[OK]   all $n addons Grand Reef depends on are installed") }
    $names = Get-DependencyNames
    $list = (@($miss | ForEach-Object { if ($names[$_]) { "$($names[$_]) ($_)" } else { $_ } })) -join ', '
    return @("[WARN] Grand Reef depends on $($miss.Count) addon(s) this PC doesn't have: $list. Without them Workbench can't start the map ('Can't initialize engine'). Fix: find each one in the Arma Reforger Workshop (by name, or paste the GUID into the search) and download it, then Doctor again.")
}

function Get-LayerRefMap {
    # layer name -> set of "GUID|path" references, from the working-tree layers.
    Initialize-LayerScan
    $dir = Join-Path $script:MapRepo (Get-PrefabGuardCfg).layersFolder
    $map = @{}
    if (-not (Test-Path -LiteralPath $dir)) { return $map }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.layer' -File)) {
        $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        $map[$f.BaseName] = [Bushwar.LayerScan]::PrefabRefs($text)
    }
    return $map
}

function Find-MissingPrefabs {
    # Pure (no repo access) so it can be smoke-tested. Returns one entry per top folder
    # whose referenced files aren't under ANY of the roots, biggest first.
    # $Known (optional): paths already found inside packed Workshop addons.
    param($LayerRefs, [string[]]$Roots, [string[]]$BaseRoots, $Known = $null)
    $need = @{}
    foreach ($ln in $LayerRefs.Keys) {
        foreach ($e in $LayerRefs[$ln]) {
            $path = $e.Substring($e.IndexOf('|') + 1)
            $seg = $path.Split('/')[0]
            if ($BaseRoots -contains $seg) { continue }
            if (-not $need.ContainsKey($path)) { $need[$path] = @{} }
            $need[$path][$ln] = $true
        }
    }
    $by = @{}
    foreach ($path in $need.Keys) {
        $hit = ($null -ne $Known -and $Known.Contains($path))
        if (-not $hit) { foreach ($r in $Roots) { if (Test-Path -LiteralPath (Join-Path $r $path)) { $hit = $true; break } } }
        if ($hit) { continue }
        $seg = $path.Split('/')[0]
        if (-not $by.ContainsKey($seg)) { $by[$seg] = @{ Root = $seg; Total = 0; Layers = @{}; Example = $path } }
        $by[$seg].Total++
        foreach ($ln in $need[$path].Keys) { $by[$seg].Layers[$ln] = $true }
    }
    return @($by.Values | Sort-Object { $_.Total } -Descending)
}

function Get-DependencyWarnings {
    # @{ Lines; Missing } - Missing is the number of unresolved prefab paths.
    $refs = Get-LayerRefMap
    if ($refs.Count -eq 0) { return @{ Lines = @('[INFO] dependency check skipped - no layers found'); Summary = ''; Missing = 0 } }
    $roots = @(Get-AddonContentRoots)
    $pcfg = Get-PrefabGuardCfg
    $baseRoots = @($pcfg.baseGameRoots) + @($pcfg.ignoreRoots)
    $missing = @(Find-MissingPrefabs -LayerRefs $refs -Roots $roots -BaseRoots $baseRoots)
    # v0.27.5: loose files leave gaps -> look inside packed Workshop addons too (only now,
    # so a PC with everything unpacked never pays for reading paks).
    $packs = @{ Read = 0; Failed = @() }
    if ($missing.Count -gt 0) {
        $packs = Get-PackedAddonFiles -Bases (Get-AddonBases)
        if ($packs.Read -gt 0) { $missing = @(Find-MissingPrefabs -LayerRefs $refs -Roots $roots -BaseRoots $baseRoots -Known $packs.Known) }
    }
    $checked = "$($roots.Count) addon folder(s)"
    if ($packs.Read -gt 0) { $checked += " and $($packs.Read) packed Workshop addon(s)" }
    if ($missing.Count -eq 0) {
        return @{ Lines = @("[OK]   every addon prefab the layers use was found ($checked checked)"); Summary = ''; Missing = 0 }
    }
    $total = 0
    foreach ($m in $missing) { $total += $m.Total }
    $folders = (@($missing | ForEach-Object { $_.Root }) | Select-Object -First 6) -join ', '
    $failed = @($packs.Failed)
    if ($failed.Count -gt 0) {
        # Some packs couldn't be read, so "not found" proves nothing: say so quietly, no
        # [WARN]/[ATTN]. The ship-time PREFAB GUARD still catches a real strip.
        $lines = @("[INFO] $total prefab path(s) the layers use (under $folders) couldn't be checked: Foreman couldn't read $($failed.Count) packed Workshop addon(s) on this PC. If those objects show up in Workbench you're fine - the ship-time PREFAB GUARD still protects the team. Post this line in chat so Foreman can be taught this pack format.")
        foreach ($f in @($failed | Select-Object -First 3)) { $lines += "[INFO]   couldn't read $f" }
        return @{ Lines = $lines; Summary = ''; Missing = $total }
    }
    $lines = @()
    foreach ($m in $missing) {
        $who = (@($m.Layers.Keys | Sort-Object) | Select-Object -First 4) -join ', '
        $lines += "[WARN] $($m.Total) prefab(s) under '$($m.Root)/' were NOT found in any addon folder (e.g. $($m.Example)); used by: $who. An addon is missing or OUT OF DATE - if Workbench opens with this, it will STRIP them from those layers on save. Update/install the addon that provides '$($m.Root)/' (the Fireforce props pack, most likely), then run Doctor again."
    }
    if ($packs.Read -gt 0) {
        $lines += "[INFO] ($checked were checked, Workshop packs included, so these really are missing here: update the props packs in the Workshop, or install the one that's absent.)"
    } else {
        $lines += "[INFO] (No packed Workshop addons were found in the usual folders either. If your Workshop addons live somewhere else, add that folder to extraAddonFolders. The ship-time PREFAB GUARD is what actually protects the team.)"
    }
    $summary = "[WARN] $total prefab path(s) the layers use were NOT found in any addon folder here (folders: $folders). An addon is missing or out of date - Workbench would STRIP these from the layers on save. Update/install the props addons, then hit Doctor for the full list."
    return @{ Lines = $lines; Summary = $summary; Missing = $total }
}

function Get-LayerViolations {
    # LAYER GUARD classification (v0.26 - trust model, design ruling 2026-10-20).
    # Layers have no owners: a name like Joe_ or mike_ is a label, not a lock, and
    # whoever is working an area ships its layers. Foreman never challenges or drops a
    # REAL edit to any layer. What it still does:
    #   Churn - a changed layer whose content is identical to master's (a Workbench
    #           re-save, Test-LayerIsChurn) -> dropped, so noise can't collide with a
    #           teammate's real edit. The safety snapshot holds it anyway.
    #   Base  - a real edit to a base layer (sharedLayers) -> ships if the stick is
    #           free or yours; WAITS (nothing dropped) if someone else holds it - the
    #           stick GATE, see Get-StickGate.
    #   Edits - every other real layer edit -> ships.
    # Two people editing the same layer at once is still caught at push (*.layer is
    # -merge in the map repo): SHIP stops with the work committed locally, never overwritten.
    param($Plan)
    $result = @{ Base = @(); Churn = @(); Edits = @() }
    if (-not $script:Cfg.PSObject.Properties['layers']) { return $result }   # framework seed without layer rules
    $re = $script:Cfg.layers.layerFileRegex
    $shared = @($script:Cfg.layers.sharedLayers)
    foreach ($p in @($Plan.Other)) {
        $m = [regex]::Match($p, $re)
        if (-not $m.Success) { continue }
        $name = $m.Groups[1].Value
        if (Test-LayerIsChurn $p) { $result.Churn += $p; continue }
        if (@($shared | Where-Object { $_ -ieq $name }).Count -gt 0) { $result.Base += $p }
        else { $result.Edits += $p }
    }
    return $result
}

function Get-BaseLayerPaths([string[]]$Paths) {
    # the base-layer files (layers.sharedLayers) among $Paths
    $out = @()
    if (-not $script:Cfg.PSObject.Properties['layers']) { return $out }
    $re = $script:Cfg.layers.layerFileRegex
    $shared = @($script:Cfg.layers.sharedLayers)
    foreach ($p in @($Paths)) {
        if (-not $p) { continue }
        $m = [regex]::Match($p, $re)
        if ($m.Success -and @($shared | Where-Object { $_ -ieq $m.Groups[1].Value }).Count -gt 0) { $out += $p }
    }
    return $out
}

function Get-StickGate {
    # THE STICK GATE (v0.26, chazman69 2026-10-20). A base layer is one unmergeable file for
    # the whole map: if two people change it at once, git stops the second ship and one
    # of them redoes their work by hand. So while someone ELSE holds the stick, your
    # base-layer edits wait (nothing is dropped). Stick free: they just ship - nobody was
    # in there, and a same-layer clash with an earlier ship is still a CONFLICT stop.
    # Stick yours: they ship and the stick goes back. 'none' | 'ok' | 'blocked'
    param([string[]]$BaseFiles, [string]$Holder, [string]$Me)
    if (@($BaseFiles | Where-Object { $_ }).Count -eq 0) { return 'none' }
    if ($Holder -and -not ($Me -and ($Holder -ieq $Me))) { return 'blocked' }
    return 'ok'
}

function Get-StickWaitMessage([string[]]$BaseFiles, $Stick, [string]$Backup, [string]$Next = 'SHIP again') {
    $names = (@($BaseFiles) | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
    $since = ''
    if ($Stick.Since) { $since = " (since $($Stick.Since))" }
    $where = 'your session is untouched on this PC'
    if ($Backup) { $where += " and backed up to GitHub ($Backup)" }
    return "$($Stick.Holder) holds the base layers$since, so your edits to $names can't ship yet: base layers can't be merged, and shipping now would leave one of you redoing their work by hand. Nothing was dropped - $where. Ask $($Stick.Holder) in the group chat; once they've shipped (it hands the stick back), $Next. If they changed the same layer, it will then stop with a CONFLICT and a human combines the two."
}

function Confirm-StickGate {
    # Runs right after the backup, BEFORE any guard repairs or discards a file: someone
    # else holds the stick + you really changed a base layer -> stop with nothing touched.
    # Returns @{ Proceed; Notes }.
    param($Plan, [string]$Backup)
    $out = @{ Proceed = $true; Notes = @() }
    $base = @(Get-BaseLayerPaths @($Plan.Other) | Where-Object { -not (Test-LayerIsChurn $_) })
    if ($base.Count -eq 0) { return $out }
    $s = $null
    try { $s = Get-LayerStick -Fresh } catch { }
    $holder = ''
    if ($s) { $holder = $s.Holder }
    if ((Get-StickGate $base $holder (Get-MyName)) -eq 'blocked') {
        $out.Proceed = $false
        $out.Notes += "[STOP] $(Get-StickWaitMessage $base $s $Backup)"
    }
    return $out
}

function Confirm-LayerGuard {
    # v0.26: no dialog and no discarding of real work. Drops pure re-saves (content
    # identical to master; the safety snapshot taken before this still holds them) and
    # notes base-layer edits (the stick gate already ran: Confirm-StickGate).
    # Returns @{ Proceed; Replan; Notes }.
    param($Plan)
    $out = @{ Proceed = $true; Replan = $false; Notes = @() }
    $lg = Get-LayerViolations $Plan
    if ($lg.Base.Count -gt 0) {
        $names = ($lg.Base | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
        $out.Notes += "[OK] Base-layer edits ship: $names"
    }
    if ($lg.Churn.Count -gt 0) {
        foreach ($p in $lg.Churn) { Run-Git $script:MapRepo @('checkout', '--', $p) | Out-Null }
        $names = ($lg.Churn | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
        $out.Notes += "[OK] Left out $(@($lg.Churn).Count) layer re-save(s) whose content is identical to master's: $names (Workbench save noise; kept in the safety snapshot)."
        $out.Replan = $true
    }
    return $out
}

# --------------------------------------------------------------- layer stick
# The BASE layers (default + the generator layers) are one whole-map file each and
# a .layer can never be merged - but deleting generated trees/roads off your build
# site is sometimes unavoidable. The LAYER STICK serializes that: a tiny committed
# file (collaboration/LAYER-STICK.md) names who may edit the base layers right now.
# Commit-gated like the engine's tile claims and WORLD-LOCK: tap in = write your
# name + push; tap out = clear it (a ship hands it back automatically).

function Get-MyName {
    $n = (Run-Git $script:MapRepo @('config', 'user.name')).Out
    if ($n) { return $n.Trim() }
    return ''
}

function Parse-LayerStick([string]$text) {
    # machine lines inside the doc:  "holder: NAME"  +  "since: WHEN"  (nobody = free)
    $holder = ''; $since = ''
    if ($text) {
        $m = [regex]::Match($text, '(?im)^holder:[ \t]*([^\r\n]+)')
        if ($m.Success) { $holder = $m.Groups[1].Value.Trim() }
        $m = [regex]::Match($text, '(?im)^since:[ \t]*([^\r\n]+)')
        if ($m.Success) { $since = $m.Groups[1].Value.Trim() }
    }
    if ($holder -ieq 'nobody' -or $holder -eq '-') { $holder = '' }
    if ($since -eq '-') { $since = '' }
    return @{ Holder = $holder; Since = $since }
}

function Get-StickFileRel {
    if (-not $script:Cfg.PSObject.Properties['layers']) { return $null }
    if (-not $script:Cfg.layers.PSObject.Properties['stickFile']) { return $null }
    return [string]$script:Cfg.layers.stickFile
}

function Get-LayerStick([switch]$Fresh) {
    # $null = this project has no stick (framework seed / file not landed yet).
    # origin/master is the live truth (claims are commit-gated); local file is fallback.
    $rel = Get-StickFileRel
    if (-not $rel) { return $null }
    $repo = $script:MapRepo
    if ($Fresh) { Run-Git $repo @('fetch', 'origin', '--quiet') | Out-Null }
    $r = Run-Git $repo @('show', "origin/$($script:Cfg.defaultBranch):$rel")
    $text = $null
    if ($r.Code -eq 0) { $text = $r.Out }
    else {
        $p = Join-Path $repo $rel
        if (Test-Path $p) { $text = Get-Content $p -Raw -Encoding UTF8 }
    }
    if ($null -eq $text) { return $null }
    return (Parse-LayerStick $text)
}

function Test-IHoldStick {
    # cheap local check (no fetch) - used for plan labels and the ship auto-release.
    # Legit holds are always pushed, so the local copy can't claim a hold you don't have.
    $rel = Get-StickFileRel
    if (-not $rel) { return $false }
    $p = Join-Path $script:MapRepo $rel
    if (-not (Test-Path $p)) { return $false }
    $me = Get-MyName
    if (-not $me) { return $false }
    $s = Parse-LayerStick (Get-Content $p -Raw -Encoding UTF8)
    return ($s.Holder -and ($s.Holder -ieq $me))
}

function Set-LayerStickFile([string]$holder, [string]$since) {
    # rewrite just the machine lines in the working-tree copy; keep UTF-8 BOM
    $rel = Get-StickFileRel
    $p = Join-Path $script:MapRepo $rel
    if (-not (Test-Path $p)) { throw 'The layer-stick file is not in your copy yet - START SESSION once, then try again.' }
    $text = Get-Content $p -Raw -Encoding UTF8
    $text = [regex]::Replace($text, '(?im)^holder:[^\r\n]*', "holder: $holder")
    $text = [regex]::Replace($text, '(?im)^since:[^\r\n]*', "since: $since")
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($true)))
}

function Invoke-StickTap {
    # One button, two moves: free -> tap IN (claim), held by me -> tap OUT (release).
    # Held by someone else -> refuse with their name.
    $repo = $script:MapRepo
    $master = $script:Cfg.defaultBranch
    $rel = Get-StickFileRel
    if (-not $rel) { throw 'This project has no layer stick configured.' }
    $me = Get-MyName
    if (-not $me) { throw 'Your git name is not set - run Doctor first so the stick knows who you are.' }
    $s = Get-LayerStick -Fresh
    if (-not $s) { throw 'No layer-stick file in the map repo yet - START SESSION once to pull the latest, then try again.' }
    if ($s.Holder -and ($s.Holder -ine $me)) {
        $since = ''
        if ($s.Since) { $since = " (since $($s.Since))" }
        throw "$($s.Holder) holds the base layers$since. Wait for their ship, or ping them in the group chat."
    }
    $state = Get-RepoState
    if ($state.Branch -ne $master) { throw "You're on branch '$($state.Branch)', not $master - START SESSION first." }
    if ($state.Behind -gt 0) {
        # a claim only counts on the team's LATEST base layers - never tap on a stale copy
        if ($state.DirtyCount -gt 0) {
            throw 'Teammates shipped after you started - SHIP SESSION first (shipping passes the stick around safely), then START SESSION, then tap in.'
        }
        $r = Run-Git $repo @('pull', '--ff-only', 'origin', $master)
        if ($r.Code -ne 0) { throw "Couldn't pull the team's latest before tapping - post in the group chat. ($($r.Out))" }
    }
    # off-PC backup first: a tap pushes, and on a push race it rebases over your session
    $bk = $null
    try {
        $bk = Backup-Session -Label 'tap'
    } catch {
        throw "Couldn't back up your session to GitHub, so the stick wasn't touched. ($($_.Exception.Message))"
    }
    $tapIn = (-not $s.Holder)
    if ($tapIn) {
        Set-LayerStickFile $me (Get-Date -Format 'yyyy-MM-dd HH:mm')
        $msg = "layer-stick: $me taps IN (base layers)"
    } else {
        Set-LayerStickFile 'nobody' '-'
        $msg = "layer-stick: $me taps OUT"
    }
    # commit ONLY the stick file (session work stays uncommitted), push it out now -
    # the claim protects nobody until it's on origin.
    $r = Run-Git $repo @('commit', '-m', $msg, '--', $rel)
    if ($r.Code -ne 0) { throw "Couldn't record the tap: $($r.Out)" }
    $r = Run-Git $repo @('push', 'origin', $master)
    if ($r.Code -ne 0) {
        # push race (someone shipped - or tapped - this second): rebase our one tiny
        # commit on top and retry; autostash carries any uncommitted session work.
        $r2 = Run-Git $repo @('pull', '--rebase', '--autostash', 'origin', $master)
        if ($r2.Code -ne 0) {
            if (Test-RebaseInProgress $repo) { Run-Git $repo @('rebase', '--abort') | Out-Null }
            throw "Couldn't land your tap - someone probably grabbed the stick in the same moment. Hit Refresh to see who holds it, then try again. ($($r2.Out))"
        }
        $r = Run-Git $repo @('push', 'origin', $master)
        if ($r.Code -ne 0) { throw "Push failed (internet? sign-in?) - your tap is NOT visible to the team yet. ($($r.Out))" }
    }
    $bref = ''
    if ($bk) { $bref = $bk.Remote }
    return @{ TappedIn = $tapIn; Me = $me; Backup = $bref }
}

function Invoke-Ship {
    # Direct-to-master (design ruling 2026-07-06): filter -> commit -> push master.
    # Push race: pull --rebase (disjoint per-tile lanes rebase clean) and retry.
    # Shared regenerable index files (GrandReef.terr/tileMap.conf/rdb) auto-resolve
    # master-wins (Resolve-SharedRebase). Only a genuine SAME-tile clash hard-stops.
    param($Plan, [string]$Summary)
    $repo = $script:MapRepo
    $master = $script:Cfg.defaultBranch
    if (Get-WorkbenchRunning) { throw 'Workbench is running — close it, then ship.' }

    $branch = (Run-Git $repo @('rev-parse', '--abbrev-ref', 'HEAD')).Out
    if ($branch -ne $master) {
        throw "You're on branch '$branch', not $master (an old session?). Post in the group chat before shipping — don't lose whatever's on it."
    }

    # discard churn + excluded shared files
    foreach ($n in $Plan.ChurnTiles.Keys) {
        foreach ($p in $Plan.ChurnTiles[$n]) { Run-Git $repo @('checkout', '--', $p) | Out-Null }
    }
    foreach ($p in $Plan.Excluded) { Run-Git $repo @('checkout', '--', $p) | Out-Null }

    $left = (Run-Git $repo @('status', '--porcelain')).Out
    if (-not $left) { throw 'Nothing real to ship (only engine noise). Hit START SESSION — it cleans the noise and finishes any leftover ship automatically.' }

    # LAYER STICK: hand it back with this ship — the tap-out rides the same commit,
    # so the release becomes visible exactly when the base-layer edits do.
    $stickReleased = $false
    try {
        if (Test-IHoldStick) { Set-LayerStickFile 'nobody' '-'; $stickReleased = $true }
    } catch { }

    if (-not $Summary) { $Summary = 'build session' }
    Run-Git $repo @('add', '-A') | Out-Null
    $r = Run-Git $repo @('commit', '-m', "[build] $Summary")
    if ($r.Code -ne 0) { throw "Commit failed: $($r.Out)" }

    $notes = @()
    $r = Run-Git $repo @('push', 'origin', $master)
    if ($r.Code -ne 0) {
        # someone landed first — pull their work underneath ours and retry
        $r = Run-Git $repo @('pull', '--rebase', 'origin', $master)
        if ($r.Code -ne 0) {
            # rebase paused on conflict. Auto-resolve the shared regenerable index files
            # (master wins); hard-stop only if a real per-tile file clashed = same tile.
            $res = Resolve-SharedRebase $repo $master
            if (-not $res.Ok) {
                Run-Git $repo @('rebase', '--abort') | Out-Null
                throw "CONFLICT: you and a teammate changed the same file(s): $($res.Bad -join ', '). Your work is committed locally and safe. If those are world layers, you both worked the same layer; if they're terrain tiles, you both sculpted the same spot. A human picks how to combine them - nothing was overwritten. STOP and post in the group chat. Once a teammate has landed the combined version, press START SESSION - it syncs by itself."
            }
            if ($res.Resolved.Count -gt 0) {
                $names = ($res.Resolved | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
                $notes += "[FIX] auto-merged $($res.Resolved.Count) shared index file(s) with the team (master wins, Workbench regenerates them on next save; your sculpts untouched): $names"
            }
            if ($res.Layers -and $res.Layers.Count -gt 0) {
                $names = ($res.Layers.Keys | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
                $notes += "[FIX] $names clashed only in Workbench's auto-generated header (BSP/bounds) - kept the side with the real edits, nothing lost; Workbench rebuilds the header on next save."
            }
        }
        # stick GATE, second look: did someone tap in while we were shipping? (the pull
        # just updated origin/master, so Get-LayerStick needs no fetch)
        $mineBase = @(Get-BaseLayerPaths @(((Run-Git $repo @('diff', '--name-only', "origin/$master", 'HEAD')).Out -split "`r?`n")))
        if ($mineBase.Count -gt 0) {
            $s = Get-LayerStick
            $holder = ''
            if ($s) { $holder = $s.Holder }
            if ((Get-StickGate $mineBase $holder (Get-MyName)) -eq 'blocked') {
                throw "They tapped in while you were shipping. $(Get-StickWaitMessage $mineBase $s '' 'press START SESSION to finish this ship') (Your session is committed on this PC, not pushed.)"
            }
        }
        $r = Run-Git $repo @('push', 'origin', $master)
        if ($r.Code -ne 0) { throw "Push still failing (internet? credentials?) — your work IS committed locally and safe. ($($r.Out))" }
    }
    if ($stickReleased) { $notes += '[OK] Layer stick handed back (holder: nobody) - it shipped with this session.' }
    return @{ Branch = $master; Notes = $notes }
}

# ------------------------------------------------------------- team status

function Get-TeamStatus {
    $repo = $script:MapRepo
    # the header's sync line reads this: a failed fetch must not show as "up to date"
    $script:FetchOk = ((Run-Git $repo @('fetch', 'origin', '--prune', '--quiet')).Code -eq 0)

    # stray branches = remote branches holding work NOT merged into master.
    # merged leftovers are invisible (they're already in everyone's map).
    $merged = @{}
    $m = Run-Git $repo @('branch', '-r', '--merged', "origin/$($script:Cfg.defaultBranch)")
    if ($m.Code -eq 0 -and $m.Out) {
        foreach ($line in ($m.Out -split "`r?`n")) { $merged[$line.Trim()] = 1 }
    }
    $fmt = '%(refname:short)|%(committerdate:relative)|%(authorname)'
    $r = Run-Git $repo @('for-each-ref', '--sort=-committerdate', "--format=$fmt", 'refs/remotes/origin')
    $sessions = @()
    if ($r.Code -eq 0 -and $r.Out) {
        foreach ($line in ($r.Out -split "`r?`n")) {
            $parts = $line -split '\|'
            if ($parts.Count -lt 3) { continue }
            $full = $parts[0]
            if ($merged.ContainsKey($full)) { continue }
            $name = $full -replace '^origin/', ''
            if ($name -eq $script:Cfg.defaultBranch) { continue }
            if ($name -eq 'HEAD') { continue }
            if ($name -eq 'origin') { continue }
            $sessions += ("{0}  ({1}, {2})" -f $name, $parts[2], $parts[1])
        }
    }
    if ($sessions.Count -eq 0) { $sessions = @('(none - good)') }

    # what landed on master lately
    $r = Run-Git $repo @('log', "origin/$($script:Cfg.defaultBranch)", '--pretty=%h %an: %s', '-6')
    $landed = @()
    if ($r.Code -eq 0 -and $r.Out) { $landed = $r.Out -split "`r?`n" }

    # WORLD-LOCK active claims
    $claims = @()
    $lockPath = Join-Path $repo $script:Cfg.worldLockFile
    if (Test-Path $lockPath) {
        $txt = Get-Content $lockPath -Raw -Encoding UTF8
        $m = [regex]::Match($txt, '## Active claims(.*?)(---|\z)', 'Singleline')
        if ($m.Success) {
            foreach ($line in ($m.Groups[1].Value -split "`r?`n")) {
                $t = $line.Trim()
                if (-not $t) { continue }
                if ($t.StartsWith('<!--')) { continue }
                if ($t.StartsWith('*(none')) { continue }
                $claims += $t
            }
        }
    }
    return @{ Sessions = $sessions; Landed = $landed; Claims = $claims }
}

# ------------------------------------------------------------------ doctor

function Ask-ShipName {
    # the name work ships under (also who holds the layer stick, and whose backups are whose)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $n = [Microsoft.VisualBasic.Interaction]::InputBox(
        "What name should your work ship under? The team sees it on everything you ship.`n`n(e.g. Mike)",
        'BUSHWAR Foreman - your name', '')
    if (-not $n -or -not $n.Trim()) { return '' }
    $n = $n.Trim()
    $r = Run-Git $script:MapRepo @('config', '--local', 'user.name', $n)
    if ($r.Code -ne 0) { return '' }
    return $n
}

function Invoke-Doctor([switch]$Interactive) {
    # Plain words on every line: this is read by builders, not developers. The last line
    # is the verdict, so nobody has to judge 15 lines themselves.
    $results = @()
    # git
    if ($script:Git) { $results += '[OK]   Git is installed (through GitHub Desktop or Git for Windows)' }
    else { $results += '[FAIL] Git is missing. Install GitHub Desktop and sign in.' }
    # repo
    if (Test-MapRepo $script:MapRepo) { $results += "[OK]   Your copy of the map: $($script:MapRepo)" }
    else { $results += "[FAIL] The map folder Foreman uses isn't a copy of the map: $($script:MapRepo). Screenshot this into the group chat." }
    # identity
    $n = (Run-Git $script:MapRepo @('config', 'user.name')).Out
    if (-not $n -and $Interactive) {
        $n = Ask-ShipName
        if ($n) { $results += "[FIX]  Your work now ships under the name: $n" }
    }
    if ($n) { $results += "[OK]   Your name on shipped work: $n" }
    else { $results += "[WARN] No name set for your work. Press Doctor again and type your name when it asks." }
    $e = (Run-Git $script:MapRepo @('config', 'user.email')).Out
    if (-not $e) { $results += '[WARN] No email set, so SHIP will fail. In GitHub Desktop: File > Options > Git, fill in your email, then press Doctor again.' }
    # safety snapshots + GitHub backups (v0.26): reassurance, not instructions
    try {
        $snaps = @(Get-SafetySnapshots)
        $mine = "$((Get-BackupCfg).Prefix)/$(Get-BackupOwner)/"
        $rb = Run-Git $script:MapRepo @('ls-remote', 'origin', "$mine*")
        if ($rb.Code -eq 0) {
            $remote = @($rb.Out -split "`r?`n" | Where-Object { $_ -match "`t" })
            $results += "[OK]   Backups: $($snaps.Count) on this PC, $($remote.Count) on GitHub (unshipped work is backed up every $((Get-BackupCfg).Minutes) min while Foreman is open)"
        } else {
            $results += "[WARN] Couldn't check your GitHub backups. If GitHub is unreachable below, fix that first."
        }
        if ($snaps.Count -gt 0) { $results += '[INFO] Lost a file? It is in a backup. Ask in the group chat and someone will restore it.' }
    } catch { }
    # origin reachable
    $r = Run-Git $script:MapRepo @('ls-remote', '--heads', 'origin')
    if ($r.Code -eq 0) { $results += '[OK]   Connected to GitHub' }
    else { $results += "[FAIL] Can't reach GitHub. Check your internet, or sign in again in GitHub Desktop." }
    # Workbench link + the stale-duplicate trap (the thing that bit Mike). Launch runs
    # the same repair silently; here it may also ask to move a stale duplicate out.
    $results += (Repair-WorkbenchLink -Interactive:$Interactive).Lines
    $wbExe = $null
    try { $wbExe = Find-WorkbenchExe } catch { }
    if ($wbExe -and (Test-WorkbenchNeedsLauncher)) {
        $results += "[WARN] Workbench's last start on this PC failed with 'Can't initialize engine'. The usual cause is a missing addon - the map's own, or one a pack needs (Workbench's log lines below name it; download it from the Workshop). Otherwise Steam > Library > Arma Reforger Tools (not Experimental) > Properties > Installed Files > Verify integrity. Until then START SESSION opens the project list: pick Grand Reef there."
        try { foreach ($fl in @(Get-LaunchFailureLines @(Get-NewestMapLogText))) { $results += "[INFO]   Workbench's log: $fl" } } catch { }
        try { if (Test-BaseGameMissing -Exe $wbExe) { $results += "[FAIL] Arma Reforger (the game) wasn't found on this PC, and Workbench needs its base game (the 'Can't find 58D0FB3206B6F859 game addon' box). Install Arma Reforger in Steam, or if it's on another drive, post this report. Tools is at: $(Split-Path -Parent $wbExe)" } } catch { }
    }
    elseif ($wbExe) {
        $results += '[OK]   Arma Reforger Tools is installed (START SESSION opens it on the map for you)'
        try {
            $la = @(Get-WorkbenchLaunchArgs -Exe $wbExe -Gproj 'x')
            if ($la -contains '-addonsDir') { $results += "[OK]   Base game found in the Arma Reforger install ($(Find-GameAddonsDir)) - Foreman points Workbench at it" }
            elseif (Test-BaseGameMissing -Exe $wbExe) { $results += "[FAIL] Arma Reforger (the game) wasn't found on this PC, and Workbench needs its base game (this is the 'Can't find 58D0FB3206B6F859 game addon' box). Install Arma Reforger in Steam, or if it's on another drive, post this report so Foreman can be taught where. Tools is at: $(Split-Path -Parent $wbExe)" }
        } catch { }
    }
    else { $results += "[WARN] Couldn't find Arma Reforger Tools in Steam. Install it (Steam > Library > Tools), or open it yourself after START SESSION." }
    # map dependencies (v0.27.7): is every addon the map's addon.gproj lists installed?
    try { $results += @(Get-MissingDependencyLines) }
    catch { $results += "[INFO] addon dependency check couldn't run: $($_.Exception.Message)" }
    # dependency prefabs (v0.25): do the prefabs the layers use actually exist on this machine?
    try { $results += (Get-DependencyWarnings).Lines }
    catch { $results += "[INFO] dependency check couldn't run: $($_.Exception.Message)" }
    $results += "[INFO] Foreman v$script:ForemanVersion"
    # verdict
    $bad = @($results | Where-Object { $_ -match '^\[(FAIL|WARN)\]' }).Count
    if ($bad -eq 0) { $results += "[OK]   ALL GOOD - you're ready to START SESSION." }
    else { $results += "[ATTN] $bad thing(s) above need attention. Screenshot this Activity box into the group chat before you build." }
    return $results
}

# ------------------------------------------------------------------- boot

function Show-Fatal([string]$msg) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($msg, 'BUSHWAR Foreman — cannot start') | Out-Null
    } catch { Write-Host "FATAL: $msg" }
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
$script:BootNotes = @()
try {
    $script:Git = Find-Git
    if (-not $script:Git) { throw 'Could not find git (neither on PATH nor inside GitHub Desktop). Install GitHub Desktop first.' }
    $script:CredArgs = Git-CredHelperArgs   # explicit GCM so private-repo auth works even when git has no global helper
    $script:Cfg = Load-Config
    $script:Local = Load-LocalConfig
    $updateState = Invoke-SelfUpdate
    $script:MapRepo = Resolve-MapRepo
} catch {
    Show-Fatal $_.Exception.Message
}
# Workbench link, every launch: a new builder is linked before they ever open Tools, and a
# link that went missing heals itself. Quiet when fine; never blocks launch.
try {
    # not under -SmokeTest: it must never write into a real addons folder (its own check
    # runs the repair against a throwaway one)
    if (-not $SmokeTest) {
        foreach ($l in (Repair-WorkbenchLink).Lines) {
            if ($l -notmatch '^\[OK\]') { $script:BootNotes += $l }
        }
    }
} catch {
    $script:BootNotes += "[WARN] Workbench link check failed ($($_.Exception.Message)) - press Doctor."
}

# ------------------------------------------------------------------ UI

Add-Type -AssemblyName PresentationFramework

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BUSHWAR Foreman" Width="980" Height="720" MinWidth="900" MinHeight="620" WindowStartupLocation="CenterScreen"
        Background="#1e2320" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <!-- amateur-friendly chrome: rounded hover-lit buttons + dark, wrapped tooltips.
         Every control carries a plain-words ToolTip - hovering IS the manual. -->
    <Style TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/>
      <Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.8"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.6"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#262c27"/>
      <Setter Property="Foreground" Value="#e8e4d8"/>
      <Setter Property="BorderBrush" Value="#5a655c"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="ContentTemplate">
        <Setter.Value>
          <DataTemplate>
            <TextBlock Text="{Binding}" TextWrapping="Wrap" MaxWidth="420" FontSize="13"/>
          </DataTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="140"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">
        <Image x:Name="imgLogo" Height="42" Margin="0,0,14,0" VerticalAlignment="Center"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="lblProject" Text="..." FontSize="20" FontWeight="Bold" Foreground="#e8e4d8"/>
          <TextBlock x:Name="lblRepo" Text="..." Foreground="#8a9585"/>
          <TextBlock x:Name="lblIdentity" Text="" Foreground="#8a9585"/>
        </StackPanel>
      </StackPanel>
      <StackPanel DockPanel.Dock="Right" HorizontalAlignment="Right">
        <TextBlock x:Name="lblWorkbench" Text="Workbench: ?" FontWeight="Bold" Foreground="#e8e4d8" HorizontalAlignment="Right"
                   ToolTip="Whether Arma Reforger Tools is running right now. START and SHIP refuse while it's open - Workbench only reads files when it starts, and keeps writing them until it exits."/>
        <TextBlock x:Name="lblBranch" Text="branch: ?" Foreground="#8a9585" HorizontalAlignment="Right"
                   ToolTip="How many of your changes SHIP SESSION would send to the team right now. Workbench's save noise is not counted: it never ships."/>
        <TextBlock x:Name="lblSync" Text="" Foreground="#8a9585" HorizontalAlignment="Right"
                   ToolTip="Whether you have everything the team has shipped. If updates are waiting, START SESSION pulls them in."/>
        <TextBlock x:Name="lblVersion" Text="" Foreground="#6a7568" FontSize="11" HorizontalAlignment="Right" Margin="0,2,0,0"/>
      </StackPanel>
    </DockPanel>

    <!-- action buttons -->
    <UniformGrid Grid.Row="1" Columns="6" Margin="0,0,0,10">
      <Button x:Name="btnStart" Content="▶  START SESSION" Height="46" Margin="0,0,6,0"
              Background="#3f6b3f" Foreground="White" FontWeight="Bold" FontSize="14" BorderThickness="0"
              ToolTip="STEP 1 - press this FIRST, with Workbench closed.&#10;&#10;It downloads everyone's latest work so you build on the newest map, then opens Workbench straight on the map for you. It refuses to run while Workbench is open (Workbench only reads files when it starts), and it finishes any ship that didn't go out last time."/>
      <Button x:Name="btnShip" Content="⬆  SHIP SESSION" Height="46" Margin="6,0,6,0"
              Background="#7a5c2e" Foreground="White" FontWeight="Bold" FontSize="14" BorderThickness="0"
              ToolTip="STEP 3 - press this when you're done building (Workbench closed).&#10;&#10;It scans what you changed and lists it on the left. Nothing is sent yet - you get to look, type a one-liner, and press Confirm. Engine noise is thrown away for you automatically."/>
      <Button x:Name="btnStick" Content="✋  TAP IN" Height="46" Margin="6,0,6,0"
              Background="#5c4a7a" Foreground="White" FontWeight="Bold" BorderThickness="0"
              ToolTip="The LAYER STICK - checking who holds it..."/>
      <Button x:Name="btnRefresh" Content="⟳  Refresh" Height="46" Margin="6,0,6,0"
              Background="#39423c" Foreground="White" BorderThickness="0"
              ToolTip="Re-checks everything: your unshipped work, what the team landed, who holds the layer stick, and the world locks. Safe to press any time - it changes nothing."/>
      <Button x:Name="btnDoctor" Content="✚  Doctor" Height="46" Margin="6,0,6,0"
              Background="#39423c" Foreground="White" BorderThickness="0"
              ToolTip="Something feels wrong? This checks your whole setup - git, the map folder, your GitHub sign-in, and the link Workbench reads - and fixes what it safely can. Run it whenever Foreman or Workbench acts weird."/>
      <Button x:Name="btnHelp" Content="❓  Help" Height="46" Margin="6,0,0,0"
              Background="#39423c" Foreground="White" BorderThickness="0"
              ToolTip="The Field Guide - the whole ritual explained in plain words, plus what Foreman protects you from. Two minutes, worth it."/>
    </UniformGrid>

    <!-- the one thing to do right now -->
    <Border Grid.Row="2" Background="#2a302b" CornerRadius="4" Padding="10,6" Margin="0,0,0,10"
            ToolTip="Foreman always tells you the ONE thing to do next, right here. If you're ever lost, do what this line says.">
      <TextBlock x:Name="lblNext" Text="..." FontSize="15" FontWeight="Bold" Foreground="#e8e4d8"/>
    </Border>

    <!-- main panels -->
    <Grid Grid.Row="3">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- left: ship preview -->
      <GroupBox Grid.Column="0" Header="Your session (what will ship)" Foreground="#e8e4d8" Margin="0,0,6,0" BorderBrush="#39423c"
                ToolTip="Everything Foreman will send to the team when you press Confirm. How to read the labels:&#10;&#10;SCULPT - terrain you shaped (ships)&#10;LAYER - a world layer you changed (ships, whoever's name is on it)&#10;BASE - a base layer you changed (ships; say so in chat)&#10;FILE - a normal changed file (ships)&#10;churn - a re-save identical to master, or tile/engine noise: left out (layers are still kept in the safety snapshot)&#10;shared - a regenerating index file, kept out on purpose&#10;&#10;Before anything is filtered, Foreman saves your whole session in a local safety snapshot.">
        <DockPanel Margin="6">
          <StackPanel DockPanel.Dock="Bottom">
            <TextBlock Text="One line: what did you build?" Foreground="#8a9585" Margin="0,8,0,2"/>
            <TextBox x:Name="txtSummary" Height="28" Padding="6,4" Background="#2a302b" Foreground="#e8e4d8" BorderBrush="#39423c"
                     ToolTip="One short line so the team knows what landed - e.g. 'finished ardmore farm' or 'cleared trees for the depot pad'. It shows up in everyone's LANDED ON MASTER list."/>
            <Button x:Name="btnConfirmShip" Content="Confirm - ship to the team" Height="34" Margin="0,8,0,0"
                    Background="#8a6a33" Foreground="White" FontWeight="Bold" BorderThickness="0" IsEnabled="False"
                    ToolTip="Sends everything listed above to the team. No review step - your teammates get it the next time they press START SESSION. If someone shipped seconds before you, Foreman slots their work underneath yours automatically."/>
          </StackPanel>
          <ListBox x:Name="lstPlan" Background="#171b18" Foreground="#cfd6c8" BorderThickness="0" FontFamily="Consolas" FontSize="12"/>
        </DockPanel>
      </GroupBox>

      <!-- right: team -->
      <GroupBox Grid.Column="1" Header="The team" Foreground="#e8e4d8" Margin="6,0,0,0" BorderBrush="#39423c">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="6">
          <StackPanel>
            <TextBlock Text="UNFINISHED WORK ON GITHUB (should say none)" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,2,0,2"
                       ToolTip="Old side-branches on GitHub holding work that never made it onto master. In the direct-to-master model this list should be EMPTY - if your name is here, ask in the group chat how to land or bin it."/>
            <ItemsControl x:Name="lstSessions" Foreground="#cfd6c8" FontFamily="Consolas" FontSize="12"/>
            <TextBlock Text="LATEST SHIPPED BY THE TEAM" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,12,0,2"
                       ToolTip="The team's changelog - the most recent sessions everyone shipped. You get all of this on your next START SESSION."/>
            <ItemsControl x:Name="lstLanded" Foreground="#cfd6c8" FontFamily="Consolas" FontSize="12"/>
            <TextBlock Text="LAYER STICK (who may edit the base layers)" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,12,0,2"
                       ToolTip="One person in the BASE layers at a time (default, Forests, Vegetation, Water and the road layers): they are one unmergeable file each. While someone holds the stick, nobody else's base-layer edits can ship. Shipping hands it back automatically."/>
            <ItemsControl x:Name="lstStick" Foreground="#cfd6c8" FontFamily="Consolas" FontSize="12"/>
            <TextBlock Text="WORLD-LOCK CLAIMS (global passes)" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,12,0,2"
                       ToolTip="Map-wide jobs that can't run in parallel - water flatten, generator runs, satmap bakes. A claim here means someone is doing one of those; don't sculpt near their work until it's released. (Normally the integrator's business.)"/>
            <ItemsControl x:Name="lstClaims" Foreground="#cfd6c8" FontFamily="Consolas" FontSize="12"/>
          </StackPanel>
        </ScrollViewer>
      </GroupBox>
    </Grid>

    <!-- log -->
    <GroupBox Grid.Row="4" Header="Activity" Foreground="#e8e4d8" Margin="0,10,0,0" BorderBrush="#39423c"
              ToolTip="Foreman narrates everything it does here. [OK] = done, [FIX] = it repaired something for you, [STOP] = read the line - it names its own fix. Screenshot this box when you ask for help in the group chat.">
      <TextBox x:Name="txtLog" IsReadOnly="True" Background="#171b18" Foreground="#9fae97" BorderThickness="0"
               FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
    </GroupBox>
  </Grid>
</Window>
'@

try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $ui = @{}
    foreach ($name in @('imgLogo','lblProject','lblRepo','lblIdentity','lblWorkbench','lblBranch','lblSync','lblVersion','lblNext','btnStart','btnShip','btnStick','btnRefresh','btnDoctor','btnHelp','lstPlan','txtSummary','btnConfirmShip','lstSessions','lstLanded','lstStick','lstClaims','txtLog')) {
        $ui[$name] = $window.FindName($name)
        if (-not $ui[$name]) { throw "UI element missing from XAML: $name" }
    }
    # brand: window icon + header wordmark (official BUSHWAR mark)
    $icoPath = Join-Path $script:ForemanRoot 'assets\icon.ico'
    if (Test-Path $icoPath) {
        $window.Icon = New-Object System.Windows.Media.Imaging.BitmapImage ([Uri]$icoPath)
    }
    $logoPath = Join-Path $script:ForemanRoot 'assets\logo.png'
    if (Test-Path $logoPath) {
        $ui.imgLogo.Source = New-Object System.Windows.Media.Imaging.BitmapImage ([Uri]$logoPath)
    }
} catch {
    Show-Fatal "UI failed to load: $($_.Exception.Message)"
}

$script:PendingPlan = $null
$script:SummaryNudged = $false
$script:Shippable = 0        # what SHIP would send, from the last plan
$script:Problem = $null      # a [STOP] waiting on the user; shown in the NEXT line until their next action
$script:StartedAt = $null    # last successful START this run
$script:WbHandoff = $null    # after START: opening | notfound | failed | manual
$script:FetchOk = $null
$script:Behind = 0

function Log([string]$msg) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $ui.txtLog.AppendText("[$stamp] $msg`r`n")
    $ui.txtLog.ScrollToEnd()
}

$script:BusyButtons = @('btnStart', 'btnShip', 'btnStick', 'btnRefresh', 'btnDoctor', 'btnHelp', 'btnConfirmShip')
$script:BusyWas = @{}
function Invoke-Busy([string]$msg, [scriptblock]$work) {
    # Git work runs on the UI thread, so without this the window just freezes ("Not
    # responding") with every button still live and a double-click queues a second run.
    # Grey the buttons, show the wait cursor, say how long, and paint that BEFORE the work.
    foreach ($b in $script:BusyButtons) { $script:BusyWas[$b] = $ui[$b].IsEnabled; $ui[$b].IsEnabled = $false }
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    $script:Problem = $null   # a new action clears the last [STOP]
    if ($msg) { Log $msg }
    $ui.lblNext.Text = 'Working... (Foreman may look frozen for a bit - leave it open)'
    $ui.lblNext.Foreground = '#cfd6c8'
    $window.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
    try {
        & $work
    } finally {
        # restore at idle priority: clicks queued while frozen land on disabled buttons
        $window.Dispatcher.BeginInvoke([action]{
            foreach ($b in $script:BusyButtons) { $ui[$b].IsEnabled = $script:BusyWas[$b] }
            $ui.btnConfirmShip.IsEnabled = ($script:Shippable -gt 0)   # the work may have re-planned
            $window.Cursor = $null
            Update-NextHint
        }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    }
}

function Refresh-Header {
    $ui.lblProject.Text = $script:Cfg.projectName
    $ui.lblRepo.Text = $script:MapRepo
    $ui.lblVersion.Text = "Foreman v$script:ForemanVersion"
    # who am I? the name this machine's work ships under (was Doctor-only before)
    $who = (Run-Git $script:MapRepo @('config', 'user.name')).Out
    if ($who) {
        $ui.lblIdentity.Text = "You: $who"
        $ui.lblIdentity.Foreground = '#8a9585'
    } else {
        $ui.lblIdentity.Text = 'You: no name yet - press Doctor to set it'
        $ui.lblIdentity.Foreground = '#d98a8a'
    }
    $state = Get-RepoState
    $script:Behind = $state.Behind
    # count what SHIP would actually send (the plan), not raw changed files: one Workbench
    # save rewrites ~1,155 tiles of pure noise, and that number only frightens people
    if ($state.Branch -ne $script:Cfg.defaultBranch) {
        $ui.lblBranch.Text = "on '$($state.Branch)', not the shared map - ask in the group chat"
        $ui.lblBranch.Foreground = '#d98a8a'
    } else {
        $ui.lblBranch.Text = "Ready to ship: $($script:Shippable) file(s)"
        $ui.lblBranch.Foreground = '#8a9585'
    }
    # plain-language team sync - report the fact; the NEXT banner owns the action
    if ($script:FetchOk -eq $false) {
        $ui.lblSync.Text = "can't reach GitHub - check your internet"
        $ui.lblSync.Foreground = '#e8c56a'
    } elseif ($state.Behind -gt 0) {
        $word = if ($state.Behind -eq 1) { 'update' } else { 'updates' }
        $ui.lblSync.Text = ("{0} {1} team {2} waiting" -f ([char]0x2B07), $state.Behind, $word)
        $ui.lblSync.Foreground = '#e8c56a'
    } else {
        $ui.lblSync.Text = 'up to date with the team'
        $ui.lblSync.Foreground = '#7fbf7f'
    }
    Update-NextHint
}

function Set-Hint([string]$text, [string]$color) {
    $ui.lblNext.Text = $text
    $ui.lblNext.Foreground = $color
}

function Update-NextHint {
    # the one line for people who don't read: what do I do RIGHT NOW? Order matters: a
    # problem beats everything, then what Workbench is doing, then ship/start.
    $wb = Get-WorkbenchRunning
    if ($wb) {
        $ui.lblWorkbench.Text = 'Workbench: RUNNING'
        $ui.lblWorkbench.Foreground = 'Orange'
    } else {
        $ui.lblWorkbench.Text = 'Workbench: closed'
        $ui.lblWorkbench.Foreground = '#7fbf7f'
    }
    if ($script:Problem) { Set-Hint $script:Problem '#e07a7a'; return }
    if ($wb) {
        if ($script:StartedAt) {
            Set-Hint 'BUILDING - when you stop: Save (rebuild the normal map if you sculpted), close Workbench, then SHIP SESSION' 'Orange'
        } elseif ($script:Behind -gt 0) {
            Set-Hint "STOP - Workbench is open on an OLD map. Close it fully, press START SESSION, then build." '#e07a7a'
        } else {
            Set-Hint "Workbench was already open. If you didn't press START SESSION first, close it and do that now." 'Orange'
        }
        return
    }
    $since = 0
    if ($script:StartedAt) { $since = ((Get-Date) - $script:StartedAt).TotalSeconds }
    switch ($script:WbHandoff) {
        'opening' {
            if ($since -lt 180) { Set-Hint 'NEXT >>  Workbench is opening on the map (about a minute). Open the Grand Reef world when it appears, then build.' '#8fd08f' }
            else { Set-Hint "NEXT >>  Workbench hasn't opened. Open Arma Reforger Tools from Steam, then pick Grand Reef." '#e8c56a' }
            return
        }
        'notfound' { Set-Hint "NEXT >>  Open Arma Reforger Tools from Steam, then pick Grand Reef. (Doctor tells you if it's installed.)" '#e8c56a'; return }
        'failed' { Set-Hint "NEXT >>  Workbench didn't open. Open it from Steam, then pick Grand Reef." '#e8c56a'; return }
        'manual' { Set-Hint 'NEXT >>  Open Workbench and the Grand Reef world, then build.' '#8fd08f'; return }
        'launcher' { Set-Hint 'NEXT >>  In the Workbench project list, pick Grand Reef and press Open, then build.' '#e8c56a'; return }
    }
    if ($script:Shippable -gt 0) {
        Set-Hint 'NEXT >>  SHIP SESSION  (you have work the team hasn''t got yet)' '#e8c56a'
    } else {
        Set-Hint 'NEXT >>  START SESSION  (it opens Workbench on the map for you)' '#8fd08f'
    }
}

function Set-Problem([string]$msg) {
    # a [STOP] must reach the one line people read, not just the Activity box
    # whole message (it names its own fix), trimmed to fit the line
    $short = $msg
    if ($short.Length -gt 170) { $short = $short.Substring(0, 167) + '...' }
    $script:Problem = "STOPPED: $short  (Details in the Activity box.)"
    Log "[STOP] $msg"
    Update-NextHint
}

function Refresh-Team {
    try {
        $t = Get-TeamStatus
        $ui.lstSessions.ItemsSource = @($t.Sessions)
        $ui.lstLanded.ItemsSource = @($t.Landed)
        if (@($t.Claims).Count -gt 0) { $ui.lstClaims.ItemsSource = @($t.Claims) }
        else { $ui.lstClaims.ItemsSource = @('(none - global passes free)') }
        Refresh-Stick
    } catch {
        Log "Team status failed: $($_.Exception.Message)"
    }
}

function Refresh-Stick {
    # panel line + button label + hover hint all follow the live claim
    # (Get-TeamStatus just fetched). Labels stay SHORT so they never clip;
    # the ToolTip carries the full plain-words explanation per state.
    $hand = [string]([char]0x270B)
    $s = Get-LayerStick
    $script:StickHolder = ''
    if ($s) { $script:StickHolder = $s.Holder }
    if ($null -eq $s) {
        $ui.lstStick.ItemsSource = @('(no stick file yet - START SESSION to get the latest)')
        $ui.btnStick.Content = "$hand  TAP IN"
        $ui.btnStick.ToolTip = "The LAYER STICK - one person in the map's BASE layers at a time (default, Forests, Vegetation, Water and the road layers).`n`nYour copy of the map doesn't have the stick file yet - press START SESSION once to get the team's latest, then this button works."
        return
    }
    $me = Get-MyName
    if (-not $s.Holder) {
        $ui.lstStick.ItemsSource = @('(free - tap in BEFORE you start on a base layer)')
        $ui.btnStick.Content = "$hand  TAP IN"
        $ui.btnStick.ToolTip = "The LAYER STICK is FREE. Only needed for base layers; skip it for everything else.`n`nAbout to work a BASE layer (default, Forests, Vegetation, Water and the road layers)? Tap in first. While you hold it, nobody else's base-layer edits can ship, so nobody ends up redoing work by hand. Shipping hands it back automatically.`n`nForgot to tap in? If the stick is still free when you ship, your base-layer edits just ship."
    } elseif ($me -and ($s.Holder -ieq $me)) {
        $ui.lstStick.ItemsSource = @("YOU hold the base layers (since $($s.Since)) - shipping hands it back")
        $ui.btnStick.Content = "$hand  TAP OUT"
        $ui.btnStick.ToolTip = "YOU hold the LAYER STICK (since $($s.Since)): the base layers are yours until you ship, and nobody else's base-layer edits can ship meanwhile. SHIP SESSION hands it back automatically; only press this if you're stopping WITHOUT shipping.`n`nTapping out never touches your work: every real edit ships when you SHIP."
    } else {
        $ui.lstStick.ItemsSource = @("$($s.Holder) is in the base layers (since $($s.Since)) - don't edit them until they ship")
        $ui.btnStick.Content = "$hand  $($s.Holder) has it"
        $ui.btnStick.ToolTip = "$($s.Holder) holds the LAYER STICK (since $($s.Since)) - they're working the base layers (default, Forests, Vegetation, Water and the road layers) right now. Don't edit those until they ship: your base-layer edits CAN'T SHIP while they hold it (nothing is dropped - they wait on your PC and in your backup).`n`nEverything else is unaffected."
    }
}

function Refresh-Plan {
    $plan = Get-ShipPlan
    $script:PendingPlan = $plan
    $items = @()
    $lg = Get-LayerViolations $plan
    $wait = ''
    if ($lg.Base.Count -gt 0) {
        try {
            $s = Get-LayerStick
            if ($s -and (Get-StickGate $lg.Base $s.Holder (Get-MyName)) -eq 'blocked') { $wait = $s.Holder }
        } catch { }
    }
    foreach ($n in ($plan.RealTiles.Keys | Sort-Object)) { $items += "SCULPT  tile $n  (ships)" }
    foreach ($p in $plan.Other) {
        if ($lg.Churn -contains $p) { $items += "churn   $p  - re-save, content identical to master (left out, kept in snapshot)" }
        elseif ($lg.Base -contains $p -and $wait) { $items += "BASE    $p  (WAITS - $wait holds the stick; nothing ships until they hand it back)" }
        elseif ($lg.Base -contains $p) { $items += "BASE    $p  (ships - base layer)" }
        elseif ($lg.Edits -contains $p) { $items += "LAYER   $p  (ships)" }
        else { $items += "FILE    $p  (ships)" }
    }
    foreach ($n in ($plan.ChurnTiles.Keys | Sort-Object)) { $items += "churn   tile $n  (auto-discarded)" }
    foreach ($p in $plan.Excluded) { $items += "shared  $p  (kept out - regenerates)" }
    if ($items.Count -eq 0) { $items = @('(no changes - build something first)') }
    $ui.lstPlan.ItemsSource = $items
    $shippable = ($plan.RealTiles.Count + $plan.Other.Count)
    $script:Shippable = $shippable
    $ui.btnConfirmShip.IsEnabled = ($shippable -gt 0)
    return $plan
}

function Show-Help {
    $helpXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BUSHWAR Foreman — Field Guide" Width="760" Height="720" WindowStartupLocation="CenterOwner"
        Background="#1e2320" FontFamily="Segoe UI" FontSize="13">
  <DockPanel Margin="16">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
      <Image x:Name="hImgLogo" Height="34" Margin="0,0,12,0"/>
      <TextBlock Text="FIELD GUIDE" FontSize="20" FontWeight="Bold" Foreground="#e8e4d8" VerticalAlignment="Center"/>
    </StackPanel>
    <UniformGrid DockPanel.Dock="Bottom" Columns="3" Margin="0,12,0,0">
      <Button x:Name="hBtnDocs" Content="Open the Builder's Guide" Height="34" Margin="0,0,6,0"
              Background="#39423c" Foreground="White" BorderThickness="0"
              ToolTip="Opens the illustrated Builder's Guide (PDF) on GitHub. Sign in to GitHub in your browser if it says page not found."/>
      <Button x:Name="hBtnShortcut" Content="Create desktop shortcut" Height="34" Margin="6,0,6,0"
              Background="#39423c" Foreground="White" BorderThickness="0"/>
      <Button x:Name="hBtnClose" Content="Got it" Height="34" Margin="6,0,0,0"
              Background="#3f6b3f" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
    </UniformGrid>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <TextBlock Foreground="#cfd6c8" TextWrapping="Wrap" Margin="0,0,0,10"
          Text="Foreman runs the whole build-session ritual for you. You never type a git command or use a command line (GitHub Desktop only keeps you signed in). Two buttons do the work: START SESSION and SHIP SESSION. The rest help."/>

        <TextBlock Text="YOUR FIRST SESSION" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,6,0,4"/>
        <TextBlock Foreground="#cfd6c8" TextWrapping="Wrap" Margin="0,0,0,10" Text="1.  Doctor checks your setup (the first time, it runs by itself when you close this guide). It ends with ALL GOOD, or a list to screenshot into the group chat.&#10;2.  START SESSION. Workbench opens on the map by itself.&#10;3.  Build. Save.&#10;4.  Close Workbench.&#10;5.  SHIP SESSION, type one line, Confirm."/>

        <TextBlock Text="THE RITUAL — every session, same three moves" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,6,0,4"/>
        <TextBlock Foreground="#cfd6c8" TextWrapping="Wrap" Margin="0,0,0,10" Text="1.  START SESSION (Workbench closed). Foreman pulls everyone's latest work — you build directly on master. Then it opens Workbench straight on the map.&#10;2.  BUILD in Workbench, in the area you're working. Use the layers that belong to that area — a name on a layer (Joe_, mike_, Malvia_) is a label, not a lock: whoever is working that area works its layers. Talk in chat when two people's areas meet. If you sculpted, do the terrain-save steps below before closing.&#10;3.  Close Workbench → SHIP SESSION. Foreman shows what ships, you type one line about what you built, hit Confirm — it saves a safety snapshot of the whole session, then lands it straight on master. No review step, no pull request. Drop a one-liner in the group chat so the team knows what landed. Done — tools down."/>

        <TextBlock Text="AFTER YOU SCULPT — the terrain-save steps" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,6,0,4"/>
        <TextBlock Foreground="#cfd6c8" TextWrapping="Wrap" Margin="0,0,0,10" Text="Moving heights doesn't update the ground's shading on its own — a stale map renders the terrain wrong. So whenever you sculpt, before you close Tools:&#10;1.  Terrain Tool → Manage tab → 'Generate normal/vegetation map…' — rebuilds the shading + vegetation from your new heights.&#10;2.  Save (Ctrl+S).&#10;3.  Close Workbench, then SHIP SESSION.&#10;This is NOT the navmesh (AI pathfinding) — that's a separate bake for later, once the world has a gamemode. The normal/vegetation map is per-tile and rebuilds on each machine, so it never blocks a merge (if it ever clashes on ship, Foreman auto-resolves it master-wins)."/>

        <TextBlock Text="LAYERS — everyone sees everyone, and work never overwrites work" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,6,0,4"/>
        <TextBlock Foreground="#cfd6c8" TextWrapping="Wrap" Margin="0,0,0,10" Text="We all build in ONE shared world, and every layer in it is a separate file on disk. All the layers load together, so you see each other's work — and because each layer is a separate file, two people working different areas never touch the same file. A .layer file can't be merged, so the one thing to avoid is two people changing the SAME layer in the same stretch of time: work the layers of the area you're in, and say in chat when you're in a shared one. Nobody owns a layer by name — we trust each other to work the layers we're meant to. If two people do change the same layer anyway, SHIP stops the second one with their work committed on their machine — nothing is overwritten — and you sort it out in chat. You see each other's latest every time you START SESSION, so ship small and often. The ground works the same way — terrain is ~1,155 per-tile files, so different areas are different files."/>

        <TextBlock Text="THE LAYER STICK: one person in the base layers at a time" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,6,0,4"/>
        <TextBlock Foreground="#cfd6c8" TextWrapping="Wrap" Margin="0,0,0,10" Text="The BASE layers (default, Forests, Vegetation, Water and the road layers) are one file each for the whole map, so everyone's areas meet in them, and two people's edits to one of them can never be combined: one person would have to redo their work by hand. So before you work one, hit TAP IN. While you hold the stick, nobody else's base-layer edits can ship (theirs wait on their PC, nothing is dropped), and if you change a base layer while someone else holds it, Foreman warns you within seconds of the save and SHIP waits until they hand it back. Forgot to tap in? If the stick is still free when you ship, your base-layer edits just ship. SHIPPING HANDS THE STICK BACK AUTOMATICALLY (tap out by hand only if you stop without shipping). Tap in right after START SESSION (never on a stale map) and hold it for a session, not a week. One quirk: base-layer trees come from a generator; if a generator re-runs, hand-deleted trees can grow back. For a permanent clearing, cut your pad out of the forest SHAPE."/>

        <TextBlock Text="WHAT FOREMAN PROTECTS YOU FROM (all learned the hard way)" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,6,0,4"/>
        <TextBlock Foreground="#cfd6c8" TextWrapping="Wrap" Margin="0,0,0,10" Text="•  Stale world: Workbench only reads files when it LOADS. Foreman refuses to start/ship while it's open, so you never build on yesterday's map.&#10;•  Save-churn: every save re-serializes the '.ttile' for all ~1,155 tiles, and a 'Generate normal/vegetation map' rewrites every '_normal', even if you touched one tile. Shipping that bloats the repo and collides with everyone. Foreman ships the tiles you actually WORKED — sculpted (a '.bterr' change) or painted (a '_layer' change) — and drops the pure serialize/normal-regen churn; each machine rebuilds those locally.&#10;•  The unmergeable index: map/resourceDatabase.rdb can never merge between two people. Foreman keeps it out of your commits entirely; Workbench rebuilds it on your machine.&#10;•  Lost work: before SHIP (or START, or a stick tap) pushes, repairs or drops anything, Foreman backs up your whole session, every changed file except tile noise: once on this PC and once on GitHub (a hidden backup, not a branch). While Foreman is open it also backs up any unshipped work every 30 minutes, so even a dead PC loses half an hour at most. No backup, no ship. Then the only layer edits it leaves out are pure re-saves whose content is IDENTICAL to master's; any real change, like a moved road point or a nudged building, ships, whoever's name is on the layer. (Before v0.26 it judged by entity count, which silently dropped moved road points and nudges: that is how road fixes on Mike's side were lost in October.) Something missing after a ship? It's in a backup: see the README, 'Getting work back'.&#10;•  Prefab loss: if an addon the map depends on (the Fireforce props pack, usually) is missing or out of date on your computer, Workbench cannot find those prefabs and quietly STRIPS them from the layer when it saves - the objects stay but turn into invisible empty entities, and some (destructible walls and roofs) vanish. Shipping that wipes the objects for everyone; it cost the plantation and the station on 08/19 and 09/17. Doctor and START SESSION now name any prefab folder they can not find, and Foreman's PREFAB GUARD checks EVERY layer you changed (your own included) before it ships: it offers to REPAIR the links from the team copy on master, or DISCARD your edits to that layer, and there is no ship-anyway. Fix it at the source - update the addon, then START SESSION.&#10;•  Ship collisions: if a teammate shipped seconds before you, Foreman slots their work underneath yours automatically (different tiles = different files, they just merge). Even when you both re-saved the shared index files (the terrain header, tile-ownership map, resource index), Foreman auto-resolves them the proven way — master wins, Workbench rebuilds them on your next save, and it names every file it merged in the Activity log. It stops dead ONLY if you both changed the exact same file — the same terrain tile, or the same world layer (which is why two people shouldn't work the same layer at once). That's the one thing it won't guess. Then it tells you to ask in chat; your work stays safe on your machine."/>

        <TextBlock Text="THE RULES (short version)" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,6,0,4"/>
        <TextBlock Foreground="#cfd6c8" TextWrapping="Wrap" Margin="0,0,0,10" Text="•  Work the layers of the area you're working, whatever name is on them; TAP IN before you touch a base layer.&#10;•  Positions come from the plan (world_coords.json / the 1:50k sheet) — don't invent locations.&#10;•  Foreman says '[STOP] CONFLICT'? Two people changed the same file. Your work is committed on your machine and safe. STOP and ask in the group chat — a human picks how to combine them. Once they've landed the combined version, just press START SESSION: Foreman sees your work is already on the team map and syncs to it by itself.&#10;•  Not merged = not done. Ship small and often."/>

        <TextBlock Text="TROUBLESHOOTING" Foreground="#a8b5a0" FontWeight="Bold" Margin="0,6,0,4"/>
        <TextBlock Foreground="#cfd6c8" TextWrapping="Wrap" Margin="0,0,0,4" Text="•  A [STOP] message names its own fix — read it first.&#10;•  'No changes seen' but you definitely built? Workbench was editing a DUPLICATE copy, not your clone — run Doctor (it checks the link Workbench reads, which Foreman sets up by itself on every launch) and ask for help.&#10;•  Workbench shows an old map? Close it fully and reopen — and always START SESSION before opening it.&#10;•  Anything else weird: screenshot + group chat. Never push through a warning."/>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@
    $hReader = New-Object System.Xml.XmlNodeReader ([xml]$helpXaml)
    $hWin = [Windows.Markup.XamlReader]::Load($hReader)
    $hWin.Owner = $window
    $hLogo = $hWin.FindName('hImgLogo')
    $logoPath = Join-Path $script:ForemanRoot 'assets\logo.png'
    if ($hLogo -and (Test-Path $logoPath)) {
        $hLogo.Source = New-Object System.Windows.Media.Imaging.BitmapImage ([Uri]$logoPath)
    }
    $hWin.FindName('hBtnClose').Add_Click({ $hWin.Close() })
    $hWin.FindName('hBtnDocs').Add_Click({
        $u = $script:Cfg.guideUrl
        if (-not $u) { $u = $script:Cfg.docsUrl }
        Start-Process $u
    })
    $hWin.FindName('hBtnShortcut').Add_Click({
        try {
            $lnk = New-DesktopShortcut
            Log "Desktop shortcut created: $lnk"
            [System.Windows.MessageBox]::Show('Shortcut created on your Desktop.', 'BUSHWAR Foreman') | Out-Null
        } catch {
            Log "Shortcut failed: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show("Couldn't create the shortcut: $($_.Exception.Message)", 'BUSHWAR Foreman') | Out-Null
        }
    })
    $hWin.ShowDialog() | Out-Null
}

# ---- events

function Refresh-All {
    # fetch first (Refresh-Team), so the header's "up to date" line is about NOW
    Refresh-Team
    Refresh-Plan | Out-Null
    Refresh-Header
}

$ui.btnRefresh.Add_Click({
    Invoke-Busy 'Refreshing...' {
        try {
            Refresh-All
            Log 'Status refreshed.'
        } catch { Set-Problem $_.Exception.Message }
    }
})

$ui.btnStart.Add_Click({
    if ($script:StartedAt -and (Get-WorkbenchRunning)) {
        Log '[OK] Session already started and Workbench is open - build away. SHIP SESSION when you are done (Workbench closed).'
        return
    }
    Invoke-Busy "Getting the team's latest work. The first time this can take a few minutes - don't close Foreman." {
        try {
            $res = Invoke-StartSession
            foreach ($n in $res.Notes) { Log $n }
        } catch { Set-Problem $_.Exception.Message; return }
        $script:StartedAt = Get-Date
        try { Refresh-All } catch { Log "[INFO] status refresh failed: $($_.Exception.Message)" }
        Log "[OK] You have the latest map. Build in your own area. When you're done: Save, close Workbench, then press SHIP SESSION. (If you sculpted: Terrain Tool > Manage > Generate normal map, then Save, before closing.)"
        # the launch is its own step: a failure here must not read as a failed pull
        try {
            $o = Open-Workbench
            $script:WbHandoff = $o.State
            Log $o.Line
        } catch {
            $script:WbHandoff = 'failed'
            Log "[WARN] Workbench didn't open ($($_.Exception.Message)). Open it from Steam yourself and choose Grand Reef."
        }
    }
})

$ui.btnShip.Add_Click({
    Invoke-Busy '' {
    try {
        $script:SummaryNudged = $false   # fresh ship cycle - reset the one-line grace
        if (Get-WorkbenchRunning) { throw 'Workbench is running. Save (+ normal-map regen if you sculpted), close it, then ship.' }
        Log 'Scanning your session...'
        $plan = Refresh-Plan
        $real = $plan.RealTiles.Count
        $churn = $plan.ChurnTiles.Count
        $files = $plan.Other.Count
        Log "Plan: $real sculpted tile(s) + $files file(s) ship; $churn churn tile(s) auto-discarded; shared index kept out. Type a summary and hit Confirm."
        # early warning (v0.25): say so NOW if a layer lost prefab links, before a summary is typed
        try {
            foreach ($l in @(Get-PrefabLoss $plan)) {
                Log "[WARN] PREFAB LOSS in $(Split-Path $l.Path -Leaf): $($l.Stripped) object(s) lost their prefab (Workbench couldn't find an addon). Confirm will offer a repair - fix the addon first (Doctor)."
            }
        } catch { Log "[INFO] prefab check couldn't run: $($_.Exception.Message)" }
    } catch {
        Set-Problem $_.Exception.Message
    }
    }
})

$ui.btnConfirmShip.Add_Click({
    Invoke-Busy 'Shipping: backing up first, then sending your work to the team. This can take a minute.' {
    try {
        if (-not $script:PendingPlan) { throw 'Scan first (SHIP SESSION).' }
        $summary = $ui.txtSummary.Text
        if (-not $summary -or -not $summary.Trim()) {
            # nudge, don't block: first empty Confirm asks for a line; a second
            # Confirm (still empty) ships anyway with a generic label.
            if (-not $script:SummaryNudged) {
                $script:SummaryNudged = $true
                $ui.txtSummary.Focus() | Out-Null
                Log 'One line first: what did you build? Type it above, then Confirm again. (Confirm again as-is to log a generic build.)'
                return
            }
        }
        $script:SummaryNudged = $false
        if (Get-WorkbenchRunning) { throw 'Workbench is running. Save, close it, then Confirm.' }
        # SAFETY SNAPSHOT + GITHUB BACKUP (v0.26): the whole session goes into a local git
        # ref AND onto GitHub BEFORE any gate, guard, filter or push. No backup, no ship.
        $script:PendingPlan = Refresh-Plan
        Log 'Backing up your session to GitHub first...'
        try {
            $snap = Backup-Session $script:PendingPlan 'ship'
        } catch {
            throw "Couldn't back up your session, so nothing was shipped or changed. ($($_.Exception.Message))"
        }
        $bref = ''
        if ($snap) {
            $bref = $snap.Remote
            Log "[OK] Backed up your session ($($snap.Files) file(s)): on GitHub as $($snap.Remote), on this PC as $($snap.Ref). If anything ever goes missing, it's in there (README: Getting work back)."
        }
        # STICK GATE (v0.26): someone else holds the stick + you changed a base layer -> wait
        $gate = Confirm-StickGate $script:PendingPlan $bref
        foreach ($n in $gate.Notes) { Log $n }
        if (-not $gate.Proceed) { Refresh-Stick; return }
        # PREFAB GUARD (v0.25): any layer that lost prefab links can't ship as-is - repair or discard
        $pguard = Confirm-PrefabGuard $script:PendingPlan
        foreach ($n in $pguard.Notes) { Log $n }
        if (-not $pguard.Proceed) { return }
        if ($pguard.Replan) {
            $plan = Refresh-Plan
            if (($plan.RealTiles.Count + $plan.Other.Count) -eq 0) {
                Log '[OK] After discarding the damaged layer edits there is nothing left to ship - fix the addon (Doctor), START SESSION, and redo it.'
                return
            }
        }
        # LAYER GUARD (v0.26): drops pure re-saves only; every real layer edit ships
        $guard = Confirm-LayerGuard $script:PendingPlan
        foreach ($n in $guard.Notes) { Log $n }
        if (-not $guard.Proceed) { return }
        if ($guard.Replan) {
            $plan = Refresh-Plan
            if (($plan.RealTiles.Count + $plan.Other.Count) -eq 0) {
                Log '[OK] Only Workbench re-saves were left (content identical to the team copy) - nothing to ship. You can close Foreman now.'
                return
            }
        }
        Log 'Shipping: filtering churn, committing, pushing to master...'
        $res = Invoke-Ship -Plan $script:PendingPlan -Summary $summary
        foreach ($n in $res.Notes) { Log $n }
        $script:PendingPlan = $null
        $ui.txtSummary.Text = ''
        $script:StartedAt = $null; $script:WbHandoff = $null   # session over
        Refresh-All
        Log '[OK] Shipped to the team - everyone gets it on their next START SESSION. Drop a one-liner in the group chat. You can close Foreman now.'
    } catch {
        Set-Problem $_.Exception.Message
    }
    }
})

$ui.btnStick.Add_Click({
    Invoke-Busy '' {
    try {
        Log 'Layer stick: checking who holds the base layers...'
        $res = Invoke-StickTap
        if ($res.Backup) { Log "[OK] Backed up your session to GitHub first: $($res.Backup)" }
        if ($res.TappedIn) {
            Log '[OK] You hold the stick - the base layers are yours until you ship (nobody else''s base-layer edits can ship meanwhile). Your next ship hands it back automatically.'
        } else {
            Log '[OK] Tapped OUT - the base layers are free for the team.'
        }
        Refresh-Stick
    } catch {
        Set-Problem $_.Exception.Message
        try { Refresh-Stick } catch { }
    }
    }
})

function Run-Doctor {
    Invoke-Busy 'Checking your setup (about 20 seconds)...' {
        try {
            $docLines = @(Invoke-Doctor -Interactive)
            foreach ($line in $docLines) { Log $line }
            Log (Send-Diagnostics -DoctorLines $docLines)
            Refresh-Header
        } catch { Set-Problem "Doctor couldn't finish: $($_.Exception.Message)" }
    }
}

$ui.btnDoctor.Add_Click({ Run-Doctor })

$ui.btnHelp.Add_Click({ Show-Help })

# Workbench watcher: keeps the NEXT hint honest, and the moment Workbench closes
# after a build it refreshes the plan and nudges toward SHIP.
$script:WbPrev = Get-WorkbenchRunning
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$timer.Add_Tick({
    $wb = Get-WorkbenchRunning
    if ($script:WbPrev -and -not $wb) {
        # transition: they just closed Workbench — surface the ship plan immediately
        $script:WbHandoff = $null
        try {
            $plan = Refresh-Plan
            $n = $plan.RealTiles.Count + $plan.Other.Count
            if ($n -gt 0) { Log 'Workbench closed — your work is ready: hit SHIP SESSION.' }
        } catch { }
        Refresh-Header
        try { Invoke-AutoBackup | Out-Null } catch { }   # back the finished session up right away
    } else {
        # the plan (refreshed on that transition, START, SHIP and Refresh) says what's
        # shippable; raw git status would count Workbench's tile noise as work
        Update-NextHint
    }
    $script:WbPrev = $wb
    # every 30 s: base-layer early warning; every 5 min: refresh who holds the stick (background fetch)
    $script:TickCount++
    if ($script:TickCount % 6 -eq 0) { try { Test-GateEarlyWarning } catch { } }
    try {
        $fp = $script:FetchProc
        if ($fp -and $fp.HasExited) {
            $script:FetchProc = $null
            Refresh-Stick
            Refresh-Header
        } elseif (-not $fp -and $script:TickCount % 60 -eq 0) {
            $script:FetchProc = Start-GitBackground @('fetch', 'origin', '--quiet')
        }
    } catch { }
})

# BASE-LAYER EARLY WARNING (v0.26): the stick gate stops a ship, but by then the work is
# done. So while you build, Foreman watches the base layers: change one while someone
# else holds the stick and it tells you within ~30 s of the save (once per layer), not
# hours later at SHIP. Uses who held the stick at the last fetch (START, Refresh, or the
# background refresh every 5 min).
$script:TickCount = 0
$script:StickHolder = ''
$script:GateWarned = @{}
$script:GateSeen = @{}
$script:GateBoxOpen = $false
function Test-GateEarlyWarning {
    if ($script:GateBoxOpen) { return }
    $h = $script:StickHolder
    if (-not $h) { return }
    if (-not $script:Cfg.PSObject.Properties['layers']) { return }
    $out = (Run-Git $script:MapRepo @('status', '--porcelain', '--', '*.layer')).Out
    if (-not $out) { return }
    $paths = @($out -split "`r?`n" | Where-Object { $_.Length -gt 3 } | ForEach-Object { $_.Substring(3).Trim('"') })
    $new = @()
    foreach ($p in @(Get-BaseLayerPaths $paths)) {
        $key = "$h|$p"
        if ($script:GateWarned.ContainsKey($key)) { continue }
        $full = Join-Path $script:MapRepo $p
        $stamp = ''
        try { $stamp = (Get-Item -LiteralPath $full).LastWriteTimeUtc.Ticks } catch { }
        if ($script:GateSeen[$p] -eq $stamp) { continue }           # this save already judged a pure re-save
        $script:GateSeen[$p] = $stamp
        if (Test-LayerIsChurn $p) { continue }
        $new += $p
    }
    if ($new.Count -eq 0) { return }
    if ((Get-StickGate $new $h (Get-MyName)) -ne 'blocked') { return }
    foreach ($p in $new) { $script:GateWarned["$h|$p"] = 1 }
    $names = ($new | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
    $msg = "You just changed $names, but $h holds the base layers.`n`nThose edits CAN'T SHIP until $h ships and hands the stick back, and if $h is changing the same layer, one of you will have to redo their work by hand.`n`nBest now: undo those base-layer changes in Workbench (your own named layers are fine), or talk to $h in the group chat. Nothing has been lost or dropped."
    Log "[WARN] $($msg -replace "`n`n", ' ')"
    $script:GateBoxOpen = $true
    try {
        [System.Windows.MessageBox]::Show($msg, 'BUSHWAR Foreman - base layer in use', 'OK', 'Warning', 'OK', 'DefaultDesktopOnly') | Out-Null
    } finally { $script:GateBoxOpen = $false }
}

# AUTO-BACKUP (v0.26): every backup.autoMinutes while Foreman is open, unshipped work is
# snapshotted and copied to GitHub in the background - a dead PC mid-session loses at
# most that much. Skips when nothing changed since the last copy.
$script:BackupTimer = $null
$bm = (Get-BackupCfg).Minutes
if ($bm -gt 0) {
    $script:BackupTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BackupTimer.Interval = [TimeSpan]::FromMinutes($bm)
    $script:BackupTimer.Add_Tick({ try { Invoke-AutoBackup | Out-Null } catch { Log "[WARN] Auto-backup hiccup: $($_.Exception.Message)" } })
}

# ---- go

if ($SmokeTest) {
    Write-Host "SMOKE: git = $script:Git"
    Write-Host "SMOKE: repo = $script:MapRepo"
    Write-Host "SMOKE: config = $($script:Cfg.projectName)"
    Write-Host "SMOKE: self-update = $updateState"
    $plan = Get-ShipPlan
    Write-Host "SMOKE: plan -> real=$($plan.RealTiles.Count) churn=$($plan.ChurnTiles.Count) excluded=$(@($plan.Excluded).Count) other=$(@($plan.Other).Count)"
    # layer-guard self-check on a fabricated plan (repo state untouched). v0.26: no owners -
    # base layers are recognised (Roads1 included), every other layer is a plain edit, and
    # a layer only counts as churn when its content equals HEAD (asserted on text below).
    $fakePlan = @{ Other = @(
        'map/Worlds/GrandReef/GrandReef_Layers/Roads1.layer',
        'map/Worlds/GrandReef/GrandReef_Layers/default.layer',
        'map/Worlds/GrandReef/GrandReef_Layers/Joe_Props.layer',
        'map/Worlds/GrandReef/GrandReef_Layers/MIKE_VEG.layer',
        'collaboration/WORLD-LOCK.md') }
    $lg = Get-LayerViolations $fakePlan
    $lgBase = @($lg.Base).Count + @(@($lg.Churn) | Where-Object { $_ -match '/(Roads1|default)\.layer$' }).Count
    $lgEdit = @($lg.Edits).Count + @(@($lg.Churn) | Where-Object { $_ -match '/(Joe_Props|MIKE_VEG)\.layer$' }).Count
    Write-Host "SMOKE: layer guard -> base=$lgBase other-layers=$lgEdit (churn=$(@($lg.Churn).Count)) (expect 2/2)"
    if ($lgBase -ne 2 -or $lgEdit -ne 2) {
        Write-Host 'SMOKE: LAYER GUARD FAILED'
        exit 1
    }
    # content-based churn (v0.26): a regrouped / reordered / jittered re-save is the same world;
    # a moved spline point, a nudged entity, a changed property or a removed entity is not.
    Initialize-LayerScan
    $lone = @('GenericEntity Sign_A : "{1111111111111111}P/sign.et" {', ' coords 10.000 5 20', ' angles 0 90 0', '}',
        'GenericEntity Sign_B : "{1111111111111111}P/sign.et" {', ' coords 30 5 40', '}',
        '$grp SplineShapeEntity {', ' Road_1 {', '  coords 100 1 100', '  Points {', '   ShapePoint "{AAAAAAAAAAAAAAAA}" {', '    Position 0 0 0', '   }',
        '   ShapePoint "{BBBBBBBBBBBBBBBB}" {', '    Position 5.5 0.2 50', '   }', '  }', ' }', '}', '') -join "`n"
    $regrouped = @('$grp SplineShapeEntity {', ' Road_1 {', '  coords 100 1 100', '  Points {', '   ShapePoint "{AAAAAAAAAAAAAAAA}" {', '    Position 0 0 0', '   }',
        '   ShapePoint "{BBBBBBBBBBBBBBBB}" {', '    Position 5.5000001 0.2 50', '   }', '  }', ' }', '}',
        '$grp GenericEntity : "{1111111111111111}P/sign.et" {', ' Sign_B {', '  coords 30 5 40', ' }', ' Sign_A {', '  coords 10 5 20', '  angles 0 90 0', ' }', '}', '') -join "`r`n"
    $movedPoint = $lone.Replace('Position 5.5 0.2 50', 'Position 7.5 0.2 50')
    $nudged = $lone.Replace('coords 30 5 40', 'coords 30.2 5 40')
    $removed = $lone.Replace("GenericEntity Sign_B : `"{1111111111111111}P/sign.et`" {`n coords 30 5 40`n}`n", '')
    $sameRe = [Bushwar.LayerCanon]::SameContent($regrouped, $lone)
    $sameMv = [Bushwar.LayerCanon]::SameContent($movedPoint, $lone)
    $sameNd = [Bushwar.LayerCanon]::SameContent($nudged, $lone)
    $sameRm = [Bushwar.LayerCanon]::SameContent($removed, $lone)
    Write-Host "SMOKE: churn by content -> regrouped=$sameRe moved-point=$sameMv nudged=$sameNd removed=$sameRm (expect True/False/False/False)"
    if (-not $sameRe -or $sameMv -or $sameNd -or $sameRm -or ($removed -eq $lone)) {
        Write-Host 'SMOKE: CONTENT CHURN FAILED'
        exit 1
    }
    # prefab-loss guard (v0.25): the incident's exact signature, on fabricated layer text.
    # Healthy layer = 3 prefabbed groups. Stripped layer = what Workbench wrote when it couldn't
    # resolve them: the first two groups became bare GenericEntity/Tree at the same coords (the
    # file starts with them - bare groups sort first) and the destructible roof vanished outright.
    Initialize-LayerScan
    $healthy = @(
        '$grp GenericEntity : "{1111111111111111}Mod/Prefabs/floor.et" {', ' {', '  coords 1 2 3', '  angles 0 10 0', ' }',
        ' {', '  coords 4 5 6', '  angles 0 20 0', '  scale 1.5', ' }', '}',
        '$grp Tree : "{2222222222222222}Veg/Prefabs/tree.et" {', ' {', '  coords 7 8 9', ' }', '}',
        'Tree : "{5555555555555555}Veg/Prefabs/lone.et" {', ' coords 20 21 22', ' angles 0 5 0', ' scale 1.029', '}',
        '$grp SCR_DestructibleEntity : "{3333333333333333}Mod/Prefabs/roof.et" {', ' {', '  coords 10 11 12', ' }', '}',
        '$grp GenericEntity : "{4444444444444444}Mod/Prefabs/wall.et" {', ' {', '  coords 13 14 15', ' }', '}', '') -join "`n"
    # (the lone `Tree : ... {` block is written in its own single form; Workbench folds it into the bare group when it strips it)
    $stripped = @(
        '$grp GenericEntity {', ' {', '  coords 1 2 3', '  angles 0 10 0', ' }',
        ' {', '  coords 4 5 6', '  angles 0 20 0', '  scale 1.5', ' }', '}',
        '$grp Tree {', ' {', '  coords 7 8 9', ' }', ' {', '  coords 20 21 22', '  angles 0 5 0', '  scale 1.029', ' }', '}',
        '$grp GenericEntity : "{4444444444444444}Mod/Prefabs/wall.et" {', ' {', '  coords 13 14 15', ' }', '}', '') -join "`n"
    $expectFixed = @(
        '$grp GenericEntity : "{1111111111111111}Mod/Prefabs/floor.et" {', ' {', '  coords 1 2 3', '  angles 0 10 0', ' }',
        ' {', '  coords 4 5 6', '  angles 0 20 0', '  scale 1.5', ' }', '}',
        '$grp Tree : "{2222222222222222}Veg/Prefabs/tree.et" {', ' {', '  coords 7 8 9', ' }', '}',
        'Tree : "{5555555555555555}Veg/Prefabs/lone.et" {', ' coords 20 21 22', ' angles 0 5 0', ' scale 1.029', '}',
        '$grp GenericEntity : "{4444444444444444}Mod/Prefabs/wall.et" {', ' {', '  coords 13 14 15', ' }', '}', '') -join "`n"
    $ana = [Bushwar.LayerScan]::Analyze($stripped, $healthy)
    $anaOk = [Bushwar.LayerScan]::Analyze($healthy, $healthy)
    $restored = 0
    $fixedTxt = [Bushwar.LayerScan]::Restore($stripped, $healthy, [ref]$restored)
    $fixedCrlf = [Bushwar.LayerScan]::Restore($stripped.Replace("`n", "`r`n"), $healthy, [ref]$restored)
    $fixedNow = [Bushwar.LayerScan]::Analyze($fixedTxt, $healthy)
    # a genuinely NEW empty entity (matches nothing committed) is counted apart from stripped ones
    $withNew = $stripped + '$grp Tree {' + "`n" + ' {' + "`n" + '  coords 99 98 97' + "`n" + ' }' + "`n" + '}' + "`n"
    $anaNew = [Bushwar.LayerScan]::Analyze($withNew, $healthy)
    Write-Host "SMOKE: prefab guard -> stripped=$($ana.Stripped) new=$($ana.NewBare) missing=$($ana.Missing) | healthy stripped=$($anaOk.Stripped) | repaired=$restored, stripped-after=$($fixedNow.Stripped), exact=$($fixedTxt -ceq $expectFixed), crlf-kept=$($fixedCrlf -ceq $expectFixed.Replace("`n", "`r`n")) | new-only new=$($anaNew.NewBare) (expect 4/0/1 | 0 | 4,0,True,True | 1)"
    if ($ana.Stripped -ne 4 -or $ana.NewBare -ne 0 -or $ana.Missing -ne 1 -or $anaOk.Stripped -ne 0 -or $anaOk.NewBare -ne 0 -or
        $restored -ne 4 -or $fixedNow.Stripped -ne 0 -or ($fixedTxt -cne $expectFixed) -or
        ($fixedCrlf -cne $expectFixed.Replace("`n", "`r`n")) -or $anaNew.NewBare -ne 1 -or $anaNew.Stripped -ne 4) {
        Write-Host 'SMOKE: PREFAB GUARD FAILED'
        exit 1
    }
    # meshed entities (v0.26.2): Malvia's 2026-10-24 office facade - 16 prefab-less GenericEntity
    # instances, each with its own MeshObject .xob and a child window prefab - tripped "16 new
    # empty objects" and the only way out was to discard the layer. A raw-mesh entity is
    # deliberate; an EMPTY one (coords only, or a mesh only on a nested child) still counts, and
    # an instance on a committed prefab's exact coords is still a strip, mesh or not.
    $meshInst = @(' {', '  components {', '   MeshObject "{6AB005B4666A8643}" {', '    Object "{44A17CB0DD93E6C3}Commercial/Assets/officeWindow02.xob"',
        '    Materials {', '     MaterialAssignClass "{6AB027064EDDD8F6}" {', '      SourceMaterial "Concrete"', '     }', '    }', '   }',
        '   RigidBody "{6AB015CD370931CB}" {', '    SimState Collision', '    ModelGeometry 1', '   }', '  }',
        '  coords {0}', '  angles 0 178 0', '  {', '   Building : "{E762906FBD94633A}Prefabs/Win_ShopHouse.et" {', '    coords -2.509 2.51 0.215', '   }', '  }', ' }')
    $meshed = @('$grp GenericEntity {') +
        ($meshInst -replace '\{0\}', '1785.499 993.938 8871.271') +
        ($meshInst -replace '\{0\}', '1785.499 999.938 8871.271') +
        # coords BEFORE components - the mesh is found after the coords line
        @(' {', '  coords 50 51 52', '  components {', '   MeshObject "{1}" {', '    Object "{2}Mod/Assets/wall02.xob"', '   }', '  }', ' }') +
        # empty: no mesh of its own, only a nested child that has one
        @(' {', '  coords 60 61 62', '  {', '   Child {', '    components {', '     MeshObject "{3}" {', '      Object "{4}Mod/Assets/x.xob"', '     }', '    }', '   }', '  }', ' }') +
        # a stripped floor that kept a mesh override: still a strip
        ($meshInst -replace '\{0\}', '1 2 3') + @('}', '')
    $anaMesh = [Bushwar.LayerScan]::Analyze(($meshed -join "`n"), $healthy)
    $anaMeshCrlf = [Bushwar.LayerScan]::Analyze(($meshed -join "`r`n"), $healthy)
    Write-Host "SMOKE: meshed entities -> new-meshed=$($anaMesh.NewMeshed) new-empty=$($anaMesh.NewBare) stripped=$($anaMesh.Stripped) | crlf $($anaMeshCrlf.NewMeshed)/$($anaMeshCrlf.NewBare)/$($anaMeshCrlf.Stripped) (expect 3/1/1 | 3/1/1)"
    if ($anaMesh.NewMeshed -ne 3 -or $anaMesh.NewBare -ne 1 -or $anaMesh.Stripped -ne 1 -or
        $anaMeshCrlf.NewMeshed -ne 3 -or $anaMeshCrlf.NewBare -ne 1 -or $anaMeshCrlf.Stripped -ne 1) {
        Write-Host 'SMOKE: MESHED ENTITIES FAILED'
        exit 1
    }
    # dependency finder: a folder present in some addon root resolves; one that isn't is named;
    # base-game roots (Prefabs/...) are never checked from disk.
    $depRoot = Join-Path $env:TEMP "foreman-dep-$PID"
    $rootA = Join-Path $depRoot 'PropsPack'
    New-Item -ItemType Directory -Path (Join-Path $rootA 'Mod\Prefabs') -Force | Out-Null
    'x' | Out-File (Join-Path $rootA 'Mod\Prefabs\floor.et') -Encoding ascii
    $refs = @{
        'Malvia_Structures' = (New-Object 'System.Collections.Generic.HashSet[string]')
        'Malvia_Vegetation' = (New-Object 'System.Collections.Generic.HashSet[string]')
    }
    [void]$refs['Malvia_Structures'].Add('AAAAAAAAAAAAAAAA|Mod/Prefabs/floor.et')
    [void]$refs['Malvia_Structures'].Add('BBBBBBBBBBBBBBBB|Prefabs/Props/base.et')
    [void]$refs['Malvia_Structures'].Add('CCCCCCCCCCCCCCCC|Gone/Prefabs/wall.et')
    [void]$refs['Malvia_Vegetation'].Add('DDDDDDDDDDDDDDDD|Gone/Prefabs/tree.et')
    $miss = @(Find-MissingPrefabs -LayerRefs $refs -Roots @($rootA) -BaseRoots @('Prefabs'))
    $missOk = ($miss.Count -eq 1 -and $miss[0].Root -eq 'Gone' -and $miss[0].Total -eq 2 -and @($miss[0].Layers.Keys).Count -eq 2)
    Remove-Item $depRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "SMOKE: dependency finder -> missing-folders=$($miss.Count) root=$(if ($miss.Count) { $miss[0].Root }) count=$(if ($miss.Count) { $miss[0].Total }) ok=$missOk (expect 1 / Gone / 2 / True)"
    if (-not $missOk) {
        Write-Host 'SMOKE: DEPENDENCY FINDER FAILED'
        exit 1
    }
    # packed Workshop addon (v0.27.5): a synthetic PAC1 pak (odd-sized DATA chunk + pad byte,
    # nested dirs) is read back to addon-relative paths that resolve the finder; a junk .pak
    # lands in Failed instead of throwing.
    $pakBase = Join-Path $env:TEMP "foreman-pak-$PID"
    $okPak = $false; $pakDetail = ''
    try {
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        $be = { param([uint32]$v) [byte[]]@((($v -shr 24) -band 255), (($v -shr 16) -band 255), (($v -shr 8) -band 255), ($v -band 255)) }
        $ascii = [System.Text.Encoding]::ASCII
        $ft = New-Object System.IO.MemoryStream
        $fw = New-Object System.IO.BinaryWriter($ft)
        $dirE = { param($w, [string]$n, [uint32]$c) $w.Write([byte]0); $w.Write([byte]$n.Length); $w.Write($ascii.GetBytes($n)); $w.Write($c) }
        $fileE = { param($w, [string]$n) $w.Write([byte]1); $w.Write([byte]$n.Length); $w.Write($ascii.GetBytes($n)); $w.Write((New-Object byte[] 24)) }
        & $dirE $fw '' 1
        & $dirE $fw 'Packed' 2
        & $fileE $fw 'a.et'
        & $dirE $fw 'Prefabs' 1
        & $fileE $fw 'wall.et'
        $fw.Flush(); $fileTable = $ft.ToArray()
        $bw.Write($ascii.GetBytes('FORM')); $bw.Write([byte[]](& $be 0)); $bw.Write($ascii.GetBytes('PAC1'))
        $bw.Write($ascii.GetBytes('HEAD')); $bw.Write([byte[]](& $be 28)); $bw.Write((New-Object byte[] 28))
        $bw.Write($ascii.GetBytes('DATA')); $bw.Write([byte[]](& $be 5)); $bw.Write((New-Object byte[] 5)); $bw.Write([byte]0)
        $bw.Write($ascii.GetBytes('FILE')); $bw.Write([byte[]](& $be $fileTable.Length)); $bw.Write($fileTable)
        $bw.Flush(); $pak = $ms.ToArray()
        $sz = & $be ($pak.Length - 8); for ($k = 0; $k -lt 4; $k++) { $pak[4 + $k] = $sz[$k] }
        New-Item -ItemType Directory -Path (Join-Path $pakBase 'GoodPack_ABC') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $pakBase 'JunkPack_DEF') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $pakBase 'GoodPack_ABC\data.pak'), $pak)
        [System.IO.File]::WriteAllBytes((Join-Path $pakBase 'JunkPack_DEF\data.pak'), [byte[]](1..64))
        $pf = Get-PackedAddonFiles -Bases @($pakBase)
        $pRefs = @{ 'Joe_Props' = (New-Object 'System.Collections.Generic.HashSet[string]') }
        [void]$pRefs['Joe_Props'].Add('EEEEEEEEEEEEEEEE|Packed/Prefabs/wall.et')
        [void]$pRefs['Joe_Props'].Add('FFFFFFFFFFFFFFFF|packed/a.et')
        [void]$pRefs['Joe_Props'].Add('1111111111111111|Packed/Prefabs/gone.et')
        $pMiss = @(Find-MissingPrefabs -LayerRefs $pRefs -Roots @() -BaseRoots @('Prefabs') -Known $pf.Known)
        $okPak = ($pf.Read -eq 1 -and @($pf.Failed).Count -eq 1 -and $pf.Known.Count -eq 2 -and
                  $pMiss.Count -eq 1 -and $pMiss[0].Total -eq 1 -and $pMiss[0].Example -eq 'Packed/Prefabs/gone.et')
        $pakDetail = "read=$($pf.Read) failed=$(@($pf.Failed).Count) files=$($pf.Known.Count) unresolved=$(if ($pMiss.Count) { $pMiss[0].Total })"
    } catch { $pakDetail = "threw: $($_.Exception.Message)" }
    finally { Remove-Item $pakBase -Recurse -Force -ErrorAction SilentlyContinue }
    # diagnostics bundle (v0.28): built in a throwaway repo from fake Workbench logs - newest
    # session only (Sessions=1), a big console.log trimmed head+tail, nothing in the
    # working tree or real index touched. The push is not exercised here.
    $dgRepo = Join-Path $env:TEMP "foreman diag it $PID"
    $dgLogs = Join-Path $dgRepo 'wblogs'
    $dgOk = $false; $dgDetail = ''
    $realRepoDg = $script:MapRepo
    try {
        New-Item -ItemType Directory -Path (Join-Path $dgLogs 'logs_2026-11-10_12-00-00'), (Join-Path $dgLogs 'logs_2026-11-09_09-00-00') -Force | Out-Null
        Run-Git $dgRepo @('init', '-q') | Out-Null
        'tracked' | Out-File (Join-Path $dgRepo 'keep.txt') -Encoding ascii
        Run-Git $dgRepo @('add', 'keep.txt') | Out-Null
        Run-Git $dgRepo @('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'init') | Out-Null
        $old = Join-Path $dgLogs 'logs_2026-11-09_09-00-00\console.log'
        'old session' | Out-File $old -Encoding ascii
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-1); (Get-Item (Split-Path $old)).LastWriteTime = (Get-Date).AddDays(-1)
        $big = New-Object byte[] (5MB); for ($k = 0; $k -lt $big.Length; $k++) { $big[$k] = 65 }
        [System.IO.File]::WriteAllBytes((Join-Path $dgLogs 'logs_2026-11-10_12-00-00\console.log'), $big)
        "Can't initialize engine" | Out-File (Join-Path $dgLogs 'logs_2026-11-10_12-00-00\error.log') -Encoding ascii
        $script:MapRepo = $dgRepo
        $bundle = New-DiagnosticsCommit -DoctorLines @('[OK]   smoke line') -LogsDir $dgLogs -Sessions 1
        $tree = (Run-Git $dgRepo @('ls-tree', '-r', '-l', $bundle.Sha)).Out
        $sizeLine = @($tree -split "`r?`n" | Where-Object { $_ -match 'logs_2026-11-10_12-00-00/console\.log$' })
        $bigSize = if ($sizeLine.Count) { [int64](($sizeLine[0] -split '\s+')[3]) } else { -1 }
        $doc = (Run-Git $dgRepo @('show', "$($bundle.Sha):doctor.txt")).Out
        $clean = -not (Run-Git $dgRepo @('status', '--porcelain', '--', 'keep.txt')).Out
        $staged = (Run-Git $dgRepo @('diff', '--cached', '--name-only')).Out
        # the real send: push to a bare "GitHub", keep-newest pruning, then the maintainer
        # download script pulls it back out
        $dgBare = Join-Path $env:TEMP "foreman-diag-bare-$PID.git"
        Run-Git $env:TEMP @('init', '-q', '--bare', $dgBare) | Out-Null
        Run-Git $dgRepo @('remote', 'add', 'origin', $dgBare) | Out-Null
        Run-Git $dgRepo @('config', 'user.name', 'Smoke Tester') | Out-Null
        $sent = Send-Diagnostics -DoctorLines @('[OK]   sent line')
        $remoteRefs = @(((Run-Git $dgRepo @('ls-remote', 'origin', 'refs/diag/*')).Out -split "`r?`n") | Where-Object { $_ -match 'refs/diag/Smoke-Tester/' })
        $dlOut = Join-Path $env:TEMP "foreman-diag-dl-$PID"
        $tool = Join-Path $script:ForemanRoot 'tools\get-diagnostics.ps1'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $tool -Repo $dgRepo -Out $dlOut -NoOpen | Out-Null
        $dlDoc = @(Get-ChildItem -LiteralPath $dlOut -Recurse -Filter 'doctor.txt' -File -ErrorAction SilentlyContinue)
        $dlOk = ($dlDoc.Count -eq 1 -and (Get-Content -LiteralPath $dlDoc[0].FullName -Raw) -match 'sent line')
        Remove-Item $dgBare, $dlOut -Recurse -Force -ErrorAction SilentlyContinue
        $dgOk = ($bundle.Logs -eq 2 -and $tree -match 'addons\.txt' -and $tree -match 'error\.log' -and $tree -notmatch 'logs_2026-11-09' -and
                 $bigSize -gt 4MB -and $bigSize -lt (4MB + 200) -and $doc -match 'smoke line' -and $doc -match 'Foreman v' -and $clean -and -not $staged -and
                 $sent -like '`[OK`]*' -and $remoteRefs.Count -eq 1 -and $dlOk)
        $dgDetail = "logs=$($bundle.Logs) files=$($bundle.Files) big=$bigSize old-left-out=$($tree -notmatch 'logs_2026-11-09') report=$($doc -match 'smoke line') untouched=$($clean -and -not $staged) pushed=$($remoteRefs.Count) downloaded=$dlOk"
        if (-not ($sent -like '`[OK`]*')) { $dgDetail += " send='$sent'" }
    } catch { $dgDetail = "threw: $($_.Exception.Message)" }
    finally {
        $script:MapRepo = $realRepoDg
        Remove-Item $dgRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "SMOKE: diagnostics bundle -> $dgDetail ok=$dgOk (expect logs=2 big~4MB old-left-out=True report=True untouched=True pushed=1 downloaded=True)"
    if (-not $dgOk) {
        Write-Host 'SMOKE: DIAGNOSTICS BUNDLE FAILED'
        exit 1
    }
    Write-Host "SMOKE: packed Workshop addon -> $pakDetail ok=$okPak (expect read=1 failed=1 files=2 unresolved=1 ok=True)"
    if (-not $okPak) {
        Write-Host 'SMOKE: PACKED ADDON READER FAILED'
        exit 1
    }
    # end-to-end on a THROWAWAY git repo (folder name has a space, like builders' paths often do):
    # commit the healthy layer, let the "stripped" version land in the working tree exactly as a
    # Workbench save would, then run the real detect -> repair path (Read-GitText / Get-PrefabLoss /
    # Invoke-PrefabRepair). The message-box flow is UI and is not exercised here.
    $itRepo = Join-Path $env:TEMP "foreman prefab it $PID"
    $itRel = 'map/Worlds/GrandReef/GrandReef_Layers/Test_Layer.layer'
    $realRepo = $script:MapRepo
    $itOk = $false; $itDetail = ''
    try {
        New-Item -ItemType Directory -Path (Join-Path $itRepo 'map/Worlds/GrandReef/GrandReef_Layers') -Force | Out-Null
        Run-Git $itRepo @('init', '-q') | Out-Null
        Run-Git $itRepo @('config', 'user.email', 'smoke@example.com') | Out-Null
        Run-Git $itRepo @('config', 'user.name', 'smoke') | Out-Null
        Run-Git $itRepo @('config', 'core.autocrlf', 'false') | Out-Null
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $itRepo $itRel), $healthy, $utf8)
        Run-Git $itRepo @('add', '-A') | Out-Null
        Run-Git $itRepo @('commit', '-q', '-m', 'healthy') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $itRepo $itRel), $stripped, $utf8)
        $script:MapRepo = $itRepo
        $itPlan = @{ Other = @($itRel, 'collaboration/WORLD-LOCK.md') }
        $found = @(Get-PrefabLoss $itPlan)
        $n = Invoke-PrefabRepair $itRel
        $onDisk = [System.IO.File]::ReadAllText((Join-Path $itRepo $itRel), [System.Text.Encoding]::UTF8)
        $after = @(Get-PrefabLoss $itPlan)
        $itOk = ($found.Count -eq 1 -and $found[0].Stripped -eq 4 -and $found[0].Repairable -and $found[0].Missing -eq 1 -and
                 $n -eq 4 -and ($onDisk -ceq $expectFixed) -and $after.Count -eq 0)
        $itDetail = "found=$($found.Count) stripped=$(if ($found.Count) { $found[0].Stripped }) repaired=$n on-disk-exact=$($onDisk -ceq $expectFixed) after=$($after.Count)"
    } catch {
        $itDetail = "EXCEPTION: $($_.Exception.Message)"
    } finally {
        $script:MapRepo = $realRepo
        Get-ChildItem $itRepo -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item $itRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "SMOKE: prefab guard end-to-end (temp repo) -> $itDetail (expect found=1 stripped=4 repaired=4 on-disk-exact=True after=0)"
    if (-not $itOk) {
        Write-Host 'SMOKE: PREFAB GUARD END-TO-END FAILED'
        exit 1
    }
    # safety snapshot (v0.26) on a throwaway repo: a modified layer, a NEW layer and a deleted
    # file all land in refs/foreman/safety/*, and the working tree + index are left exactly as they were.
    $snRepo = Join-Path $env:TEMP "foreman snap it $PID"
    $realRepo = $script:MapRepo
    $snOk = $false; $snDetail = ''
    try {
        $lay = 'map/Worlds/GrandReef/GrandReef_Layers'
        New-Item -ItemType Directory -Path (Join-Path $snRepo $lay) -Force | Out-Null
        Run-Git $snRepo @('init', '-q') | Out-Null
        Run-Git $snRepo @('config', 'user.email', 'smoke@example.com') | Out-Null
        Run-Git $snRepo @('config', 'user.name', 'smoke') | Out-Null
        Run-Git $snRepo @('config', 'core.autocrlf', 'false') | Out-Null
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $snRepo "$lay/Roads1.layer"), $lone, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $snRepo "$lay/Old.layer"), 'x', $utf8)
        $tdir = 'map/Worlds/GrandReef/GrandReef/.Data'
        New-Item -ItemType Directory -Path (Join-Path $snRepo $tdir) -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $snRepo "$tdir/GrandReef_7.ttile"), 'base', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $snRepo "$tdir/GrandReef_8.bterr"), 'base', $utf8)
        # fireforce git-ignores the never-commit index; an exclude naming it made git add fail (2026-10-21)
        [System.IO.File]::WriteAllText((Join-Path $snRepo '.gitignore'), "map/resourceDatabase.rdb`n", $utf8)
        Run-Git $snRepo @('add', '-A') | Out-Null
        Run-Git $snRepo @('commit', '-q', '-m', 'base') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $snRepo "$lay/Roads1.layer"), $movedPoint, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $snRepo "$lay/New Layer.layer"), 'new', $utf8)
        Remove-Item (Join-Path $snRepo "$lay/Old.layer") -Force
        New-Item -ItemType Directory -Path (Join-Path $snRepo 'map/Prefabs/NewFolder') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $snRepo 'map/Prefabs/NewFolder/Hut.et'), 'hut', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $snRepo "$tdir/GrandReef_7.ttile"), 'churn', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $snRepo "$tdir/GrandReef_8.bterr"), 'sculpt', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $snRepo 'map/resourceDatabase.rdb'), 'index', $utf8)
        $script:MapRepo = $snRepo
        $before = (Run-Git $snRepo @('status', '--porcelain')).Out
        $snPlan = Get-ShipPlan
        $lgSn = Get-LayerViolations $snPlan
        $snap = Save-SafetySnapshot $snPlan 'smoke'
        $after = (Run-Git $snRepo @('status', '--porcelain')).Out
        # compare blob hashes, not text: Run-Git's Out-String joins lines with CRLF on Windows
        $roadKept = (Run-Git $snRepo @('rev-parse', "$($snap.Ref):$lay/Roads1.layer")).Out -eq (Run-Git $snRepo @('hash-object', '--', "$lay/Roads1.layer")).Out
        $inNew = (Run-Git $snRepo @('show', "$($snap.Ref):$lay/New Layer.layer")).Out
        $oldGone = (Run-Git $snRepo @('cat-file', '-e', "$($snap.Ref):$lay/Old.layer")).Code -ne 0
        $inHut = (Run-Git $snRepo @('show', "$($snap.Ref):map/Prefabs/NewFolder/Hut.et")).Out
        $churnOut = (Run-Git $snRepo @('show', "$($snap.Ref):$tdir/GrandReef_7.ttile")).Out -eq 'base'
        $sculptIn = (Run-Git $snRepo @('show', "$($snap.Ref):$tdir/GrandReef_8.bterr")).Out -eq 'sculpt'
        $snOk = ($snap -and $snap.Files -eq 5 -and $inHut -eq 'hut' -and $churnOut -and $sculptIn -and $before -eq $after -and $roadKept -and $inNew -eq 'new' -and $oldGone -and
                 @($lgSn.Churn).Count -eq 0 -and @($lgSn.Base) -contains "$lay/Roads1.layer")
        $snDetail = "files=$($snap.Files) tree-untouched=$($before -eq $after) moved-point-kept=$roadKept new-kept=$($inNew -eq 'new') delete-kept=$oldGone road-edit-not-churn=$(@($lgSn.Churn).Count -eq 0) new-folder-kept=$($inHut -eq 'hut') tile-churn-left-out=$churnOut sculpt-kept=$sculptIn"
    } catch {
        $snDetail = "EXCEPTION: $($_.Exception.Message)"
    } finally {
        $script:MapRepo = $realRepo
        Get-ChildItem $snRepo -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item $snRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "SMOKE: safety snapshot (temp repo) -> $snDetail (expect files=5 and all True)"
    if (-not $snOk) {
        Write-Host 'SMOKE: SAFETY SNAPSHOT FAILED'
        exit 1
    }
    # stick gate (v0.26): base-layer edits wait only while someone ELSE holds the stick
    $gb = @(Get-BaseLayerPaths $fakePlan.Other)
    $g1 = Get-StickGate $gb 'Joe' 'Mike'
    $g2 = Get-StickGate $gb '' 'Mike'
    $g3 = Get-StickGate $gb 'mike' 'Mike'
    $g4 = Get-StickGate @() 'Joe' 'Mike'
    $g5 = Get-StickGate $gb 'Joe' ''
    Write-Host "SMOKE: stick gate -> base-files=$($gb.Count) held-by-other=$g1 free=$g2 mine=$g3 no-base=$g4 no-name=$g5 (expect 2 blocked ok ok none blocked)"
    if ($gb.Count -ne 2 -or $g1 -ne 'blocked' -or $g2 -ne 'ok' -or $g3 -ne 'ok' -or $g4 -ne 'none' -or $g5 -ne 'blocked') {
        Write-Host 'SMOKE: STICK GATE FAILED'
        exit 1
    }
    # GitHub backup (v0.26) on a throwaway repo + a local bare repo standing in for GitHub:
    # the session lands as refs/backup/<name>/<stamp>, old ones are pruned, leftover commits
    # are backed up from a clean tree, and the background auto-backup uploads.
    $bkRepo = Join-Path $env:TEMP "foreman bk it $PID"
    $bkRemote = Join-Path $env:TEMP "foreman bk remote $PID.git"
    $realRepo = $script:MapRepo
    $bkOk = $false; $bkDetail = ''
    try {
        New-Item -ItemType Directory -Path $bkRepo -Force | Out-Null
        Run-Git $env:TEMP @('-c', 'init.defaultBranch=master', 'init', '-q', '--bare', $bkRemote) | Out-Null
        Run-Git $bkRepo @('-c', 'init.defaultBranch=master', 'init', '-q') | Out-Null
        Run-Git $bkRepo @('config', 'user.email', 'smoke@example.com') | Out-Null
        Run-Git $bkRepo @('config', 'user.name', 'Smoke Tester') | Out-Null
        Run-Git $bkRepo @('config', 'core.autocrlf', 'false') | Out-Null
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $bkRepo 'a.txt'), 'base', $utf8)
        Run-Git $bkRepo @('add', '-A') | Out-Null
        Run-Git $bkRepo @('commit', '-q', '-m', 'base') | Out-Null
        Run-Git $bkRepo @('remote', 'add', 'origin', $bkRemote) | Out-Null
        Run-Git $bkRepo @('push', '-q', 'origin', 'master') | Out-Null
        $script:MapRepo = $bkRepo
        $owner = Get-BackupOwner
        $none = Get-BackupTarget $null 'smoke'
        [System.IO.File]::WriteAllText((Join-Path $bkRepo 'a.txt'), 'edit', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $bkRepo 'new.txt'), 'new', $utf8)
        $b1 = Backup-Session $null 'smoke'
        $b1Content = (Run-Git $bkRemote @('show', "$($b1.Remote):a.txt")).Out
        $b1New = (Run-Git $bkRemote @('show', "$($b1.Remote):new.txt")).Out
        foreach ($s in @('20000101-000001-000', '20000101-000002-000', '20000101-000003-000')) {
            Run-Git $bkRepo @('push', '-q', 'origin', "$($b1.Sha):refs/backup/$owner/$s") | Out-Null
        }
        $pruned = Remove-OldBackups -Keep 2
        $left = @(((Run-Git $bkRepo @('ls-remote', 'origin', "refs/backup/$owner/*")).Out -split "`r?`n") | Where-Object { $_ } | ForEach-Object { ($_ -split "`t")[-1] })
        $pruneOk = $pruned -eq 2 -and $left.Count -eq 2 -and ($left -contains $b1.Remote) -and ($left -contains "refs/backup/$owner/20000101-000003-000")
        Run-Git $bkRepo @('add', '-A') | Out-Null
        Run-Git $bkRepo @('commit', '-q', '-m', 'leftover') | Out-Null
        $b2 = Backup-Session $null 'smoke'
        $head = (Run-Git $bkRepo @('rev-parse', 'HEAD')).Out
        $b2Ok = $b2 -and $b2.Commits -eq 1 -and ((Run-Git $bkRemote @('rev-parse', $b2.Remote)).Out -eq $head)
        [System.IO.File]::WriteAllText((Join-Path $bkRepo 'a.txt'), 'auto', $utf8)
        $a1 = Invoke-AutoBackup
        if ($script:AutoBackupProc) { $script:AutoBackupProc.WaitForExit(60000) | Out-Null }
        $a2 = Invoke-AutoBackup
        $autoContent = (Run-Git $bkRemote @('show', "$($script:AutoBackupRef):a.txt")).Out
        $autoOk = $a1 -eq 'started' -and $a2 -eq 'same' -and $autoContent -eq 'auto' -and -not $script:AutoBackupFailed
        $bkOk = ($null -eq $none) -and $owner -eq 'Smoke-Tester' -and $b1 -and $b1.Files -eq 2 -and $b1Content -eq 'edit' -and $b1New -eq 'new' -and $pruneOk -and $b2Ok -and $autoOk
        $bkDetail = "owner=$owner nothing-to-do=$($null -eq $none) files=$($b1.Files) on-github=$($b1Content -eq 'edit' -and $b1New -eq 'new') pruned=$pruned kept-newest=$pruneOk leftover-commit=$b2Ok auto=$a1/$a2 auto-on-github=$autoOk"
    } catch {
        $bkDetail = "EXCEPTION: $($_.Exception.Message)"
    } finally {
        if ($script:AutoBackupProc) { try { $script:AutoBackupProc.WaitForExit(30000) | Out-Null } catch { } }
        $script:AutoBackupProc = $null; $script:AutoBackupTree = ''; $script:AutoBackupRef = ''; $script:AutoBackupFailed = $false
        $script:MapRepo = $realRepo
        foreach ($d in @($bkRepo, $bkRemote)) {
            Get-ChildItem $d -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
            Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "SMOKE: github backup (temp repos) -> $bkDetail (expect owner=Smoke-Tester, files=2, pruned=2, auto=started/same, all True)"
    if (-not $bkOk) {
        Write-Host 'SMOKE: GITHUB BACKUP FAILED'
        exit 1
    }
    # stick gate end-to-end (v0.26): Joe and Mike share a bare "GitHub". Joe holds the stick ->
    # Mike's road edit waits; Joe frees it -> it may ship; Joe taps in DURING Mike's push ->
    # the ship stops with Mike's work committed on his PC; START backs the leftover up and
    # waits; Joe frees the stick -> START lands it.
    $geRoot = Join-Path $env:TEMP "foreman gate it $PID"
    $realRepo = $script:MapRepo
    $origJ = ${function:Get-JunctionRepos}
    $geOk = $false; $geDetail = ''
    try {
        ${function:Get-JunctionRepos} = { @() }
        $geR = Join-Path $geRoot 'remote.git'; $geJ = Join-Path $geRoot 'joe'; $geM = Join-Path $geRoot 'mike'
        $lay = 'map/Worlds/GrandReef/GrandReef_Layers'
        $stickRel = Get-StickFileRel
        New-Item -ItemType Directory -Path (Join-Path $geJ $lay), (Join-Path $geJ 'collaboration') -Force | Out-Null
        Run-Git $geRoot @('-c', 'init.defaultBranch=master', 'init', '-q', '--bare', $geR) | Out-Null
        Run-Git $geJ @('-c', 'init.defaultBranch=master', 'init', '-q') | Out-Null
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $setStick = { param($who) [System.IO.File]::WriteAllText((Join-Path $geJ $stickRel), "# stick`nholder: $who`nsince: -`n", $utf8)
            Run-Git $geJ @('commit', '-q', '-m', "stick $who", '--', $stickRel) | Out-Null
            Run-Git $geJ @('push', '-q', 'origin', 'master') | Out-Null }
        foreach ($rp in @($geJ)) {
            Run-Git $rp @('config', 'user.email', 'joe@example.com') | Out-Null
            Run-Git $rp @('config', 'user.name', 'Joe') | Out-Null
            Run-Git $rp @('config', 'core.autocrlf', 'false') | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $geJ "$lay/Roads1.layer"), $lone, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $geJ $stickRel), "# stick`nholder: nobody`nsince: -`n", $utf8)
        Run-Git $geJ @('add', '-A') | Out-Null
        Run-Git $geJ @('commit', '-q', '-m', 'base') | Out-Null
        Run-Git $geJ @('remote', 'add', 'origin', $geR) | Out-Null
        Run-Git $geJ @('push', '-q', 'origin', 'master') | Out-Null
        Run-Git $geRoot @('-c', 'core.autocrlf=false', 'clone', '-q', $geR, $geM) | Out-Null
        Run-Git $geM @('config', 'user.email', 'mike@example.com') | Out-Null
        Run-Git $geM @('config', 'user.name', 'Mike') | Out-Null
        Run-Git $geM @('config', 'core.autocrlf', 'false') | Out-Null
        & $setStick 'Joe'
        $script:MapRepo = $geM
        [System.IO.File]::WriteAllText((Join-Path $geM "$lay/Roads1.layer"), $movedPoint, $utf8)
        $g1 = Confirm-StickGate (Get-ShipPlan) ''
        $waitMsg = ($g1.Notes -join ' ')
        & $setStick 'nobody'
        $g2 = Confirm-StickGate (Get-ShipPlan) ''
        & $setStick 'Joe'                                  # Joe taps in while Mike is shipping
        $raceMsg = ''
        try { Invoke-Ship -Plan (Get-ShipPlan) -Summary 'smoke road fix' | Out-Null } catch { $raceMsg = $_.Exception.Message }
        $movedHash = (Run-Git $geM @('hash-object', '--', "$lay/Roads1.layer")).Out
        $remoteRoad = (Run-Git $geR @('rev-parse', "master:$lay/Roads1.layer")).Out
        $mikeRoad = (Run-Git $geM @('rev-parse', "HEAD:$lay/Roads1.layer")).Out
        $raceOk = ($raceMsg -match 'tapped in while you were shipping') -and ($remoteRoad -ne $movedHash) -and ($mikeRoad -eq $movedHash)
        $wbOpen = [bool](Get-WorkbenchRunning)
        $startOk = $true; $landOk = $true; $startMsg = '(skipped: Workbench open)'
        if (-not $wbOpen) {
            $startMsg = ''
            try { Invoke-StartSession | Out-Null } catch { $startMsg = $_.Exception.Message }
            $bk = @(((Run-Git $geR @('for-each-ref', '--format=%(objectname)', 'refs/backup/Mike/')).Out -split "`r?`n") | Where-Object { $_ })
            $startOk = ($startMsg -match 'START SESSION again') -and ($bk -contains (Run-Git $geM @('rev-parse', 'HEAD')).Out)
            & $setStick 'nobody'
            $landMsg = ''
            try { Invoke-StartSession | Out-Null } catch { $landMsg = $_.Exception.Message }
            $landOk = (-not $landMsg) -and ((Run-Git $geR @('rev-parse', "master:$lay/Roads1.layer")).Out -eq $movedHash)
        }
        $geOk = (-not $g1.Proceed) -and ($waitMsg -match 'Joe holds the base layers') -and $g2.Proceed -and $raceOk -and $startOk -and $landOk
        $geDetail = "held-by-Joe-waits=$(-not $g1.Proceed) freed-ships=$($g2.Proceed) race-stopped-work-kept=$raceOk start-backs-up-and-waits=$startOk start-lands-after-release=$landOk"
        if (-not $geOk) { $geDetail += " | wait='$waitMsg' race='$raceMsg' start='$startMsg' land='$landMsg'" }
    } catch {
        $geDetail = "EXCEPTION: $($_.Exception.Message)"
    } finally {
        ${function:Get-JunctionRepos} = $origJ
        $script:MapRepo = $realRepo
        Get-ChildItem $geRoot -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item $geRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "SMOKE: stick gate end-to-end (temp repos) -> $geDetail (expect all True)"
    if (-not $geOk) {
        Write-Host 'SMOKE: STICK GATE END-TO-END FAILED'
        exit 1
    }
    # dependency check on the REAL layers (informational: whether prefabs resolve depends on
    # which addons this machine has). It must run cleanly and name what it can't find.
    try {
        $dw = Get-DependencyWarnings
        Write-Host "SMOKE: dependency check (real layers) -> unresolved prefab paths=$($dw.Missing) (informational)"
        foreach ($dl in @($dw.Lines | Select-Object -First 8)) { Write-Host ('SMOKE:    ' + $dl.Substring(0, [Math]::Min(190, $dl.Length))) }
    } catch {
        Write-Host "SMOKE: DEPENDENCY CHECK THREW: $($_.Exception.Message)"
        exit 1
    }
    # layer-stick parse self-check (pure text, repo untouched)
    $held = Parse-LayerStick "# stick`r`nholder: Joe`r`nsince: 2026-07-09 14:00`r`n"
    $free = Parse-LayerStick "holder: nobody`r`nsince: -`r`n"
    Write-Host "SMOKE: layer stick -> held-by=$($held.Holder) since=$($held.Since) free=$(-not $free.Holder) (expect Joe / 2026-07-09 14:00 / True)"
    if ($held.Holder -ne 'Joe' -or $held.Since -ne '2026-07-09 14:00' -or $free.Holder) {
        Write-Host 'SMOKE: LAYER STICK FAILED'
        exit 1
    }
    # dependency safety: Doctor's duplicate test must fire ONLY on the map's own project
    # folder, never on a Workshop pack a builder installed by hand into the tools addons
    # folder (throwaway temp dirs, cleaned up; nothing on the real addons path is read).
    $tmpRoot = Join-Path $env:TEMP "foreman-smoke-$PID"
    $dMap = Join-Path $tmpRoot 'MapCopy'
    $dDep = Join-Path $tmpRoot 'BushwarPack3'
    $dNone = Join-Path $tmpRoot 'NoProject'
    New-Item -ItemType Directory -Path $dMap, $dDep, $dNone -Force | Out-Null
    "GameProject {`r`n GUID `"$($script:Cfg.addonGuid)`"`r`n}" | Out-File (Join-Path $dMap 'addon.gproj') -Encoding utf8
    "GameProject {`r`n GUID `"652412D10AC38900`"`r`n}" | Out-File (Join-Path $dDep 'addon.gproj') -Encoding utf8
    $dupMap = Test-IsMapProjectFolder $dMap
    $dupDep = Test-IsMapProjectFolder $dDep
    $dupNone = Test-IsMapProjectFolder $dNone
    Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    # base-game launch check (v0.27.6): only a log that shows the engine failing counts. A
    # healthy log, one that merely names the base game GUID as a dependency, or no log at
    # all = launch directly.
    $okLog = "12:00:01.000 ENGINE       : Addon dirs:`r`n  dir: 'C:/Steam/steamapps/common/Arma Reforger Tools/Workbench/addons/'`r`n12:00:02.000 RESOURCES    : Addon: ArmaReforger ($script:BaseGameGuid)`r`n12:00:09.000 ENGINE       : Game successfully created."
    $badA = "12:00:01.000 ENGINE    (E): Game addon '$script:BaseGameGuid' not found!"
    $badB = "12:00:01.000 ENGINE    (F): Can't initialize engine"
    $lHealthy = Test-BaseGameLaunchFailed @($okLog)
    $lNone = Test-BaseGameLaunchFailed @()
    $lAddon = Test-BaseGameLaunchFailed @($okLog, $badA)
    $lEngine = Test-BaseGameLaunchFailed @($badB)
    Write-Host "SMOKE: base game -> healthy=$lHealthy no-logs=$lNone addon-missing=$lAddon cant-init=$lEngine (expect False/False/True/True)"
    if ($lHealthy -or $lNone -or -not $lAddon -or -not $lEngine) {
        Write-Host 'SMOKE: BASE GAME CHECK FAILED'
        exit 1
    }
    # Doctor quotes what the log says was missing (v0.27.8), timestamp stripped, no healthy lines
    $flLog = "12:00:01.000 RESOURCES    : Addon: ArmaReforger ($script:BaseGameGuid)`r`n12:00:01.100 ENGINE    (E): Addon 'ArmaTerrainCore' (60B524F7A5AE96A8) not found`r`n12:00:01.200 ENGINE    (F): Can't initialize engine"
    $fl = @(Get-LaunchFailureLines @($flLog))
    $flOk = ($fl.Count -eq 1 -and $fl[0] -like "ENGINE*ArmaTerrainCore*60B524F7A5AE96A8*not found")
    Write-Host "SMOKE: launch failure lines -> $($fl -join ' | ') ok=$flOk (expect the ArmaTerrainCore line only, ok=True)"
    if (-not $flOk) {
        Write-Host 'SMOKE: LAUNCH FAILURE LINES FAILED'
        exit 1
    }
    # whose log is it (v0.27.9): another project's failed start never counts against the map
    $mg = $script:Cfg.addonGuid
    $logOther = "ENGINE: Loading project 'C:/Users/x/Documents/My Games/ArmaReforgerWorkbench/addons/Mashonaland/Mashonaland.gproj'`r`n$flLog"
    $logGuid = "RESOURCES: Addon: GrandReef ($mg)`r`n$badB"
    $logId = "ENGINE: project GrandReef`r`n$badB"
    $logPath = "ENGINE: -gproj C:/Users/x/Documents/My Games/ArmaReforgerWorkbench/addons/Grand Reef/addon.gproj`r`n$badB"
    $logIdPart = "ENGINE: project GrandReefTest`r`n$badB"
    $wOther = Test-LogIsForMap -Text $logOther -Guid $mg -ProjectId 'GrandReef' -Paths @('Grand Reef\addon.gproj')
    $wGuid = Test-LogIsForMap -Text $logGuid -Guid $mg -ProjectId 'GrandReef'
    $wId = Test-LogIsForMap -Text $logId -Guid $mg -ProjectId 'GrandReef'
    $wPath = Test-LogIsForMap -Text $logPath -Guid $mg -ProjectId 'GrandReef' -Paths @('Grand Reef\addon.gproj')
    $wIdPart = Test-LogIsForMap -Text $logIdPart -Guid $mg -ProjectId 'GrandReef'
    $whoOk = (-not $wOther -and $wGuid -and $wId -and $wPath -and -not $wIdPart)
    Write-Host "SMOKE: whose log -> other-map=$wOther guid=$wGuid id=$wId gproj-path=$wPath id-prefix=$wIdPart (expect False/True/True/True/False)"
    if (-not $whoOk) {
        Write-Host 'SMOKE: LOG OWNER CHECK FAILED'
        exit 1
    }
    # -addonsDir (v0.28.1): added only when Tools lacks the base game and the game install has it
    $adT = Join-Path $env:TEMP "foreman-addonsdir-$PID"
    $toolsA = Join-Path $adT 'Tools\Workbench\addons'; $gameA = Join-Path $adT 'Arma Reforger\addons'; $docsA = Join-Path $adT 'Docs\addons'
    New-Item -ItemType Directory -Path (Join-Path $toolsA 'core'), (Join-Path $gameA 'data'), $docsA -Force | Out-Null
    'GameProject { GUID "58D0FB3206B6F859" }' | Out-File (Join-Path $gameA 'data\ArmaReforger.gproj') -Encoding ascii
    $adNeed = @(Get-WorkbenchAddonsDirs -ToolsAddons $toolsA -GameAddons $gameA -DocsAddons $docsA)
    $adNoGame = @(Get-WorkbenchAddonsDirs -ToolsAddons $toolsA -GameAddons $null -DocsAddons $docsA)
    New-Item -ItemType Directory -Path (Join-Path $toolsA 'data') -Force | Out-Null
    'GameProject { GUID "58D0FB3206B6F859" }' | Out-File (Join-Path $toolsA 'data\ArmaReforger.gproj') -Encoding ascii
    $adToolsHas = @(Get-WorkbenchAddonsDirs -ToolsAddons $toolsA -GameAddons $gameA -DocsAddons $docsA)
    # v0.28.2: Tools with the base game is never "missing"; Tools without it is, unless the game is found
    $fakeExe = Join-Path (Split-Path -Parent $toolsA) 'ArmaReforgerWorkbenchSteamDiag.exe'
    $bgHas = Test-BaseGameMissing -Exe $fakeExe
    Remove-Item (Join-Path $toolsA 'data') -Recurse -Force
    $bgLacks = Test-BaseGameMissing -Exe $fakeExe
    $bgExpect = (-not (Find-GameAddonsDir))
    Write-Host "SMOKE: base game missing -> tools-has=$bgHas tools-lacks=$bgLacks (expect False/$bgExpect)"
    if ($bgHas -or $bgLacks -ne $bgExpect) {
        Write-Host 'SMOKE: BASE GAME CHECK FAILED'
        exit 1
    }
    Remove-Item $adT -Recurse -Force -ErrorAction SilentlyContinue
    $cliOld = '12:53:58.342   ENGINE       : CLI Params: -gproj C:\x\Grand Reef\addon.gproj '
    $cliNew = '12:53:58.342   ENGINE       : CLI Params: -gproj C:\x\Grand Reef\addon.gproj -addonsDir C:\a,C:\b '
    $adOk = ($adNeed.Count -eq 3 -and $adNeed[1] -eq $gameA -and $adNoGame.Count -eq 0 -and $adToolsHas.Count -eq 0 -and
             $cliOld -notmatch '(?im)CLI Params:.*-addonsDir' -and $cliNew -match '(?im)CLI Params:.*-addonsDir')
    Write-Host "SMOKE: addonsDir -> tools-lacks-base=$($adNeed.Count) no-game=$($adNoGame.Count) tools-has-base=$($adToolsHas.Count) ok=$adOk (expect 3/0/0 ok=True)"
    if (-not $adOk) {
        Write-Host 'SMOKE: ADDONSDIR CHECK FAILED'
        exit 1
    }
    # map dependencies (v0.27.7): a Workshop folder named _<GUID> and a loose addon's own GUID
    # count as installed; a GUID a loose addon merely DEPENDS on doesn't; the base game is never asked for.
    $depT = Join-Path $env:TEMP "foreman-deps-$PID"
    New-Item -ItemType Directory -Path (Join-Path $depT 'BushwarPack2_657A1A9334708DE4'), (Join-Path $depT 'Pack3') -Force | Out-Null
    "GameProject {`r`n GUID `"66334D841E7BD416`"`r`n Dependencies {`r`n  `"652412D10AC38900`"`r`n }`r`n}" | Out-File (Join-Path $depT 'Pack3\Pack3.gproj') -Encoding utf8
    $haveT = Get-InstalledAddonGuids -Bases @($depT, (Join-Path $depT 'nope'))
    $missT = @(Find-MissingDependencies -Needed @($script:BaseGameGuid, '657A1A9334708DE4', '66334D841E7BD416', '652412D10AC38900') -Installed $haveT)
    Remove-Item $depT -Recurse -Force -ErrorAction SilentlyContinue
    $depOk = ($missT.Count -eq 1 -and $missT[0] -eq '652412D10AC38900')
    Write-Host "SMOKE: map dependencies -> installed=$($haveT.Count) missing=$($missT -join ',') ok=$depOk (expect installed=2 missing=652412D10AC38900 ok=True)"
    if (-not $depOk) {
        Write-Host 'SMOKE: MAP DEPENDENCY CHECK FAILED'
        exit 1
    }
    try {
        foreach ($dl in @(Get-MissingDependencyLines)) { Write-Host ('SMOKE: map dependencies (this PC, informational) -> ' + $dl.Substring(0, [Math]::Min(300, $dl.Length))) }
    } catch {
        Write-Host "SMOKE: MAP DEPENDENCY CHECK THREW: $($_.Exception.Message)"
        exit 1
    }
    Write-Host "SMOKE: dupe test -> map-copy=$dupMap dependency=$dupDep no-gproj=$dupNone (expect True/False/False)"
    if (-not $dupMap -or $dupDep -or $dupNone) {
        Write-Host 'SMOKE: DEPENDENCY SAFETY FAILED'
        exit 1
    }
    # Workbench auto-link (v0.27), against a stand-in clone and a throwaway addons folder so
    # nothing here can touch the real map or the real Workbench folder:
    #  - a fresh PC gets addons\<link> -> <clone>\map; a second pass changes nothing
    #  - a link left pointing at a deleted clone is replaced
    #  - a stale full copy of the repo is only reported at launch; Doctor's yes moves it OUT
    #    of addons and leaves the clone's own map folder alone (a pre-v0.27 Doctor renamed it)
    $smokeBase = Join-Path $env:TEMP "foreman-smoke-link-$PID"
    $realRepo = $script:MapRepo
    $script:AddonsRootOverride = Join-Path $smokeBase 'Workbench\addons'
    $fake = Join-Path $smokeBase 'clone'
    $checks = [ordered]@{}
    $log = @()
    try {
        $marker = Join-Path $fake ($script:Cfg.repoMarker -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force | Out-Null
        "GameProject {`r`n GUID `"$($script:Cfg.addonGuid)`"`r`n}" | Out-File $marker -Encoding utf8
        Run-Git $fake @('init', '-q') | Out-Null
        $script:MapRepo = $fake
        $linkName = $script:Cfg.workbenchLinkName
        if (-not $linkName) { $linkName = $script:Cfg.repoFolderName }
        $link = Join-Path $script:AddonsRootOverride $linkName

        $first = Repair-WorkbenchLink; $second = Repair-WorkbenchLink
        $log += $first.Lines + $second.Lines
        $made = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        $checks.created = [bool]($first.Ok -and $made -and $made.LinkType -eq 'Junction' -and (Test-SamePath @($made.Target)[0] (Get-MapProjectDir)))
        $checks.idempotent = [bool]($second.Ok -and -not (($second.Lines -join ' ') -match '\[FIX\]'))
        $gp = Get-WorkbenchProjectFile
        $checks.gproj = [bool]((Get-LongPath $gp).ToLower().StartsWith((Get-LongPath $script:AddonsRootOverride).ToLower()) -and (Test-Path $gp))

        [System.IO.Directory]::Delete($link)
        $gone = Join-Path $smokeBase 'moved-away'
        New-Item -ItemType Directory -Path $gone -Force | Out-Null
        New-Item -ItemType Junction -Path $link -Target $gone | Out-Null
        Remove-Item -LiteralPath $gone -Force
        $heal = Repair-WorkbenchLink
        $log += $heal.Lines
        $checks.healed = [bool]($heal.Ok -and (Test-SamePath @((Get-Item -LiteralPath $link -Force).Target)[0] (Get-MapProjectDir)))

        [System.IO.Directory]::Delete($link)   # no good link, so Doctor will relink at the copy's name
        $copy = Join-Path $script:AddonsRootOverride 'fireforce'
        $copyMarker = Join-Path $copy ($script:Cfg.repoMarker -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $copyMarker) -Force | Out-Null
        "GameProject {`r`n GUID `"$($script:Cfg.addonGuid)`"`r`n}" | Out-File $copyMarker -Encoding utf8
        $boot = Repair-WorkbenchLink
        $log += $boot.Lines
        $checks.staleFlaggedOnly = [bool]((($boot.Lines -join ' ') -match 'second copy') -and -not (Test-Path $link) -and ((Get-Item $copy).LinkType -ne 'Junction'))
        $script:DoctorAutoYes = $true
        $doc = Repair-WorkbenchLink -Interactive
        $script:DoctorAutoYes = $false
        $log += $doc.Lines
        $backup = Join-Path (Split-Path -Parent $script:AddonsRootOverride) 'addons_STALE_BACKUP\fireforce'
        $checks.staleMoved = [bool]($doc.Ok -and (Test-Path (Join-Path $backup 'map')) -and ((Get-Item $copy -Force).LinkType -eq 'Junction'))
        $checks.cloneIntact = [bool]((Test-Path $marker) -and -not (Test-Path (Join-Path $fake 'map_STALE_BACKUP')))
        $after = Repair-WorkbenchLink
        $log += $after.Lines
        $checks.cleanAfter = [bool]($after.Ok -and -not (($after.Lines -join ' ') -match '\[(FAIL|WARN)\]'))
    } catch {
        $log += "threw: $($_.Exception.Message)"
    } finally {
        $script:DoctorAutoYes = $false
        foreach ($c in @(Get-ChildItem -LiteralPath $script:AddonsRootOverride -Directory -Force -ErrorAction SilentlyContinue)) {
            if (@('Junction', 'SymbolicLink') -contains [string]$c.LinkType) { [System.IO.Directory]::Delete($c.FullName) }   # the link only, never its target
        }
        Remove-Item -LiteralPath $smokeBase -Recurse -Force -ErrorAction SilentlyContinue
        $script:AddonsRootOverride = $null
        $script:MapRepo = $realRepo
    }
    $summary = ($checks.Keys | ForEach-Object { "$_=$($checks[$_])" }) -join ' '
    Write-Host "SMOKE: workbench link -> $summary (expect all True)"
    if ($checks.Count -ne 8 -or @($checks.Values | Where-Object { -not $_ }).Count -gt 0) {
        foreach ($l in $log) { Write-Host "SMOKE:    $l" }
        Write-Host 'SMOKE: WORKBENCH LINK FAILED'
        exit 1
    }
    $stickState = Get-LayerStick
    if ($null -eq $stickState) { Write-Host 'SMOKE: stick file -> (none configured/landed yet)' }
    else { Write-Host "SMOKE: stick file -> holder=$(if ($stickState.Holder) { $stickState.Holder } else { '(free)' })" }
    $state = Get-RepoState
    Write-Host "SMOKE: state -> branch=$($state.Branch) dirty=$($state.DirtyCount) behind=$($state.Behind) ahead=$($state.Ahead)"
    Write-Host 'SMOKE: XAML loaded, all UI elements resolved. OK'
    exit 0
}

# Show the window IMMEDIATELY; do the slow first refresh (incl. git fetch)
# after it's on screen, so launch never looks like a dead console.
$window.Add_ContentRendered({
    Log "BUSHWAR Foreman v$script:ForemanVersion - self-update: $updateState"
    foreach ($note in $script:BootNotes) { Log $note }
    Log 'Loading status (first fetch can take a few seconds)...'
    $window.Dispatcher.Invoke([action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
    try {
        Refresh-All
        Log 'Ready. Ritual: START SESSION -> build in Workbench -> close it -> SHIP SESSION.'
    } catch {
        Set-Problem "Startup refresh failed: $($_.Exception.Message)"
    }
    # a link problem found at launch must reach the NEXT line, not just the log
    if (-not $script:Problem -and @($script:BootNotes | Where-Object { $_ -match '^\[(FAIL|WARN)\]' }).Count -gt 0) {
        $script:Problem = 'NEXT >>  Something in your setup needs a check: press Doctor.'
        Update-NextHint
    }
    $timer.Start()
    if ($script:BackupTimer) {
        $script:BackupTimer.Start()
        Log "Auto-backup is on: every $((Get-BackupCfg).Minutes) min, any unshipped work is copied to GitHub (refs/backup/$(Get-BackupOwner)/...)."
    }
    # first launch on this machine: the field guide, then Doctor (so the setup check the
    # guides promise actually happens, with its verdict on screen)
    if (-not $script:Local.seenHelp) {
        Show-Help
        $script:Local.seenHelp = $true
        Save-LocalConfig $script:Local
        Run-Doctor
    }
})
$window.ShowDialog() | Out-Null
