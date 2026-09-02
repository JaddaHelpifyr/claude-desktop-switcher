<#
.SYNOPSIS
    Account profile switcher for the Claude desktop app on Windows.

.DESCRIPTION
    Swaps the small set of files that hold your logged-in session, so you can
    keep two accounts signed in at once and flip between them without
    re-authenticating.

    Commands:
      .\claude-profile.ps1 doctor          # resolved paths + lock state
      .\claude-profile.ps1 whoami
      .\claude-profile.ps1 list
      .\claude-profile.ps1 save   <name>
      .\claude-profile.ps1 switch <name>
      .\claude-profile.ps1 delete <name>

    First-time setup:
      1. Signed into account A:  .\claude-profile.ps1 save personal
      2. Sign OUT in the app, sign in as account B
      3.                        .\claude-profile.ps1 save work
      4. From then on:          .\claude-profile.ps1 switch personal

    Step 2 is not optional. Saving twice without signing out stores the same
    account under both names; 'save' now refuses to do that.

    IMPORTANT: run this from a normal PowerShell window, not from inside
    Claude. It force-closes the app, which would kill the session running it.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('doctor', 'whoami', 'list', 'save', 'switch', 'delete', 'rename', 'label')]
    [string]$Command = 'list',

    [Parameter(Position = 1)]
    [string]$Name,

    # Second positional argument, used by 'rename'.
    [Parameter(Position = 2)]
    [string]$NewName,

    # Allow saving a profile whose account already belongs to another profile.
    [switch]$Force,

    # Skip relaunching the app after a switch.
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

# --- Paths -------------------------------------------------------------------

$ClaudeJson = Join-Path $env:USERPROFILE '.claude.json'
$Store      = Join-Path $env:USERPROFILE '.claude-profiles'
$Marker     = Join-Path $Store 'current.txt'

# The desktop app is an MSIX package. Depending on which shell you run from,
# %APPDATA% may resolve to the real Roaming folder or to the package's
# redirected view. They are the same underlying files, but only one of the two
# is guaranteed visible from any given process -- so probe rather than assume.
# The previous version assumed, silently found nothing, and "saved" empty
# profiles.
# The package family name is publisher-derived, so it is the same on every
# machine running the Store build -- but discover it anyway, so a republished
# package or a differently-packaged build does not silently break paths.
function Get-ClaudePackageFamily {
    foreach ($n in @('Claude', '*Claude*')) {
        try {
            $p = @(Get-AppxPackage -Name $n -ErrorAction Stop)
            if ($p.Count -gt 0) { return $p[0].PackageFamilyName }
        } catch { }
    }
    return 'Claude_pzs8sxrjxfjjc'   # last-known default
}

function Get-ClaudeAumid {
    try {
        $a = @(Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -eq 'Claude' })
        if ($a.Count -gt 0) { return $a[0].AppID }
    } catch { }
    return ((Get-ClaudePackageFamily) + '!Claude')
}

function Resolve-AppRoot {
    $fam = Get-ClaudePackageFamily
    $candidates = @(
        (Join-Path $env:APPDATA 'Claude'),
        (Join-Path $env:LOCALAPPDATA "Packages\$fam\LocalCache\Roaming\Claude")
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'Local State')) { return $c }
    }
    throw ("Cannot find the Claude app data folder. Tried:`n  " + ($candidates -join "`n  ") +
           "`nIs the Claude desktop app installed and signed in at least once?")
}

$AppRoot = Resolve-AppRoot
$Aumid   = Get-ClaudeAumid

# 'Local State' must travel with 'Network' -- it holds the DPAPI-wrapped AES key
# the cookie database is encrypted with. Split them and the cookies become
# undecryptable.
#
# config.json is the one that actually matters for Claude Code: it holds
# 'oauth:tokenCacheV2' (the Code-side OAuth tokens) and 'lastKnownAccountUuid'.
# Leaving it out meant a switch restored the cookies but left Code authenticated
# as the previous account.
$Items = @(
    @{ Live = Join-Path $AppRoot 'Local State';     Stored = 'Local State';     Type = 'File' },
    @{ Live = Join-Path $AppRoot 'Network';         Stored = 'Network';         Type = 'Dir'  },
    @{ Live = Join-Path $AppRoot 'Local Storage';   Stored = 'Local Storage';   Type = 'Dir'  },
    @{ Live = Join-Path $AppRoot 'Session Storage'; Stored = 'Session Storage'; Type = 'Dir'  },
    @{ Live = Join-Path $AppRoot 'config.json';     Stored = 'config.json';     Type = 'File' },
    @{ Live = $ClaudeJson;                          Stored = 'claude.json';     Type = 'File' }
)

$CookieDb   = Join-Path $AppRoot 'Network\Cookies'
$AppConfig  = Join-Path $AppRoot 'config.json'

# Written just before Restore-Profile starts mutating the live app directory and
# deleted the instant it finishes. If present at startup, a previous switch was
# interrupted mid-copy -- the live store may hold a DPAPI key from one account
# over cookies from another (undecryptable). The named profile is intact in the
# store, so we can re-apply it to return to a known-good state.
$SwitchMarker = Join-Path $Store '.switch-in-progress'

# One profile mutation at a time across every process (watcher + GUI + CLI). Two
# concurrent Restore-Profile runs over the same six files is the fastest route to
# a corrupted live store; the watcher and a manual switch can otherwise collide.
$ProfileLockName = 'Global\ClaudeSwitcherProfileOp'
$script:ProfileMutex = $null

function Enter-ProfileLock {
    $isNew = $false
    $script:ProfileMutex = New-Object System.Threading.Mutex($false, $ProfileLockName, [ref]$isNew)
    $got = $false
    try { $got = $script:ProfileMutex.WaitOne([TimeSpan]::FromSeconds(90)) }
    catch [System.Threading.AbandonedMutexException] { $got = $true }  # prior holder died mid-op; we own it now
    if (-not $got) {
        throw "Another switch or save is already in progress (waited 90s). Try again in a moment."
    }
}

function Exit-ProfileLock {
    if ($script:ProfileMutex) {
        try { $script:ProfileMutex.ReleaseMutex() } catch { }
        $script:ProfileMutex.Dispose()
        $script:ProfileMutex = $null
    }
}

# --- Text helpers (BOM-free; PS 5.1's -Encoding utf8 writes a BOM) -----------

function Write-Text {
    param([string]$Path, [string]$Value)
    [System.IO.File]::WriteAllText($Path, $Value)
}

function Read-Text {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $t = [System.IO.File]::ReadAllText($Path)
    return $t.Trim([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x0A)
}

# --- State helpers -----------------------------------------------------------

function Get-CurrentEmail {
    if (-not (Test-Path $ClaudeJson)) { return $null }
    try {
        $j = Get-Content $ClaudeJson -Raw | ConvertFrom-Json
        if ($j.oauthAccount -and $j.oauthAccount.emailAddress) { return $j.oauthAccount.emailAddress }
        return $null
    } catch { return $null }
}

# The desktop app runs two independent sessions: the Chat/Cowork web session and
# the Claude Code session. Switching accounts from the chat account menu does NOT
# move Claude Code. 'lastKnownAccountUuid' in config.json is the Code-side
# identity, and it is the one this script cares about -- it is what the weekly
# limit is charged against.
function Get-AppAccountUuid {
    if (-not (Test-Path $AppConfig)) { return $null }
    try {
        $c = Get-Content $AppConfig -Raw | ConvertFrom-Json
        return $c.lastKnownAccountUuid
    } catch { return $null }
}

function Get-CurrentUuid {
    if (-not (Test-Path $ClaudeJson)) { return $null }
    try {
        $j = Get-Content $ClaudeJson -Raw | ConvertFrom-Json
        if ($j.oauthAccount) { return $j.oauthAccount.accountUuid }
        return $null
    } catch { return $null }
}

function Get-CurrentProfile { return (Read-Text $Marker) }

function Get-ProfileAccount {
    param([string]$ProfileName)
    return (Read-Text (Join-Path (Join-Path $Store $ProfileName) 'account.txt'))
}

# Authoritative identity for a profile: the lastKnownAccountUuid inside the
# config.json that this profile would actually RESTORE. Do not use the email
# from claude.json -- it is frozen at whatever account Claude Code last fetched
# a profile for, and stays wrong through any number of account switches.
function Get-ProfileUuid {
    param([string]$ProfileName)
    $dir = Join-Path $Store $ProfileName
    $cfg = Join-Path $dir 'config.json'
    if (Test-Path $cfg) {
        try {
            $c = Get-Content $cfg -Raw | ConvertFrom-Json
            if ($c.lastKnownAccountUuid) { return $c.lastKnownAccountUuid }
        } catch { }
    }
    return (Read-Text (Join-Path $dir 'account-uuid.txt'))
}

# Human-assigned name, since nothing on disk reliably maps a UUID to an email.
function Get-ProfileLabel {
    param([string]$ProfileName)
    return (Read-Text (Join-Path (Join-Path $Store $ProfileName) 'label.txt'))
}

function Get-ShortUuid {
    param([string]$Uuid)
    if (-not $Uuid) { return '<unknown>' }
    if ($Uuid.Length -le 8) { return $Uuid }
    return $Uuid.Substring(0, 8) + '...'
}

# Which saved profile matches the account the app is on right now.
function Get-LiveProfile {
    $live = Get-AppAccountUuid
    if (-not $live) { return $null }
    foreach ($p in Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue) {
        if ($p.Name -like '.*') { continue }
        if ((Get-ProfileUuid $p.Name) -eq $live) { return $p.Name }
    }
    return $null
}

function Test-ProfileComplete {
    param([string]$ProfileName)
    $dir = Join-Path $Store $ProfileName
    if (-not (Test-Path $dir)) { return $false }
    foreach ($item in $Items) {
        if (-not (Test-Path (Join-Path $dir $item.Stored))) { return $false }
    }
    # Presence is not enough -- a profile whose config.json is truncated or whose
    # cookie DB is empty looks complete but restores a broken session. Validate
    # the two files that actually carry auth.
    $cfg = Join-Path $dir 'config.json'
    try {
        $c = Get-Content $cfg -Raw | ConvertFrom-Json
        if (-not $c.lastKnownAccountUuid) { return $false }
    } catch { return $false }
    $ck = Join-Path $dir 'Network\Cookies'
    if ((Test-Path $ck) -and ((Get-Item $ck).Length -eq 0)) { return $false }
    return $true
}

# --- App lifecycle -----------------------------------------------------------

function Test-FileUnlocked {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $true }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Close(); $fs.Dispose()
        return $true
    } catch { return $false }
}

function Stop-ClaudeApp {
    $procs = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "Closing Claude ($($procs.Count) process(es))..." -ForegroundColor Yellow
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 300
        if (Get-Process -Name 'claude' -ErrorAction SilentlyContinue) { continue }
        # Processes gone is not enough -- Electron flushes LevelDB and SQLite on
        # exit and file handles drain a moment later. Copying the cookie DB
        # mid-flush yields a profile that silently fails to authenticate, so
        # wait until it is genuinely unlocked.
        if (Test-FileUnlocked $CookieDb) { return }
    }

    if (Get-Process -Name 'claude' -ErrorAction SilentlyContinue) {
        throw "Claude processes did not exit. Close the app manually and retry."
    }
    throw "Claude exited but '$CookieDb' is still locked. Wait a few seconds and retry."
}

# --- Copy primitives ---------------------------------------------------------

function Copy-Entry {
    param([string]$From, [string]$To, [string]$Type, [string]$Label)

    # Hard failure, not a silent skip. A missing source used to return $false
    # and let the save "succeed" with an unusable profile.
    if (-not (Test-Path $From)) {
        throw "Expected '$Label' at '$From' but it does not exist. Nothing was saved."
    }

    if (Test-Path $To) { Remove-Item $To -Recurse -Force }
    $parent = Split-Path $To -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    try {
        if ($Type -eq 'Dir') { Copy-Item $From $To -Recurse -Force -ErrorAction Stop }
        else                 { Copy-Item $From $To -Force -ErrorAction Stop }
    } catch [System.IO.IOException] {
        throw "'$Label' is locked by another process ($From). Make sure Claude is fully closed."
    }
}

# --- Save / restore ----------------------------------------------------------

function Save-Profile {
    param([string]$ProfileName, [switch]$Quiet)

    $final   = Join-Path $Store $ProfileName
    $staging = Join-Path $Store ".staging-$ProfileName"
    $backup  = Join-Path $Store ".backup-$ProfileName"

    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    # Build the whole profile off to the side. Only swap it into place once
    # every item is present, so a mid-way failure can never leave a partial
    # profile behind.
    try {
        foreach ($item in $Items) {
            Copy-Entry -From $item.Live -To (Join-Path $staging $item.Stored) `
                       -Type $item.Type -Label $item.Stored
        }
        $email = Get-CurrentEmail
        if (-not $email) { throw "No signed-in account found in '$ClaudeJson'. Sign in first." }
        Write-Text (Join-Path $staging 'account.txt') $email

        # Record the UUID too. Emails are for humans; the UUID is what the
        # duplicate-account guard compares, since it comes from the same file
        # that carries the tokens.
        $uuid = Get-AppAccountUuid
        if (-not $uuid) { $uuid = Get-CurrentUuid }
        if ($uuid) { Write-Text (Join-Path $staging 'account-uuid.txt') $uuid }

        # Carry forward user-owned metadata. The staging directory REPLACES the
        # profile wholesale, so anything not copied here is destroyed -- which is
        # how every save and switch-checkpoint used to erase the label.
        foreach ($keep in @('label.txt')) {
            $old = Join-Path $final $keep
            $new = Join-Path $staging $keep
            if ((Test-Path $old) -and -not (Test-Path $new)) { Copy-Item $old $new -Force }
        }
    } catch {
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
    if (Test-Path $final)  { Move-Item $final $backup }
    try {
        Move-Item $staging $final
    } catch {
        if (Test-Path $backup) { Move-Item $backup $final }
        throw
    }
    Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue

    if (-not $Quiet) {
        Write-Host "Saved '$ProfileName' ($($Items.Count)/$($Items.Count) items) -> $(Get-ProfileAccount $ProfileName)" -ForegroundColor Green
    }
}

function Restore-Profile {
    param([string]$ProfileName)

    $src = Join-Path $Store $ProfileName
    if (-not (Test-ProfileComplete $ProfileName)) {
        throw "Profile '$ProfileName' is incomplete or missing. Re-save it while signed into that account."
    }

    # Snapshot the live state so a failure part-way through can be undone.
    $rollback = Join-Path $Store '.rollback'
    if (Test-Path $rollback) { Remove-Item $rollback -Recurse -Force }
    New-Item -ItemType Directory -Path $rollback -Force | Out-Null
    foreach ($item in $Items) {
        if (Test-Path $item.Live) {
            Copy-Entry -From $item.Live -To (Join-Path $rollback $item.Stored) `
                       -Type $item.Type -Label $item.Stored
        }
    }

    # Mark the live store as mid-mutation. If anything kills us between here and
    # the delete below (power loss, Task Manager), startup repair re-applies this
    # same profile, which is intact in the store.
    Write-Text $SwitchMarker $ProfileName

    try {
        foreach ($item in $Items) {
            Copy-Entry -From (Join-Path $src $item.Stored) -To $item.Live `
                       -Type $item.Type -Label $item.Stored
        }
    } catch {
        Write-Warning "Restore failed - rolling back to the previous session."
        foreach ($item in $Items) {
            $rb = Join-Path $rollback $item.Stored
            if (Test-Path $rb) {
                try { Copy-Entry -From $rb -To $item.Live -Type $item.Type -Label $item.Stored } catch { }
            }
        }
        # Do NOT clear the marker here. Rollback is best-effort and can itself
        # fail (e.g. the app relaunched and re-locked the cookie DB), which would
        # leave the live store inconsistent. Keeping the marker means the next
        # launch re-applies the target profile -- which is intact in the store --
        # instead of silently living with a corrupt session.
        throw
    }

    Remove-Item $SwitchMarker -Force -ErrorAction SilentlyContinue
    Remove-Item $rollback -Recurse -Force -ErrorAction SilentlyContinue
    Write-Text $Marker $ProfileName
}

# Recover from a crash inside Save-Profile's final swap. Between moving the old
# profile aside (.backup-<name>) and moving the new one into place, <name> does
# not exist; a hard kill there would otherwise strand the profile as a dotted dir
# that 'list' hides and nothing restores.
function Repair-Saves {
    foreach ($b in Get-ChildItem $Store -Directory -Filter '.backup-*' -ErrorAction SilentlyContinue) {
        $name = $b.Name.Substring('.backup-'.Length)
        $final = Join-Path $Store $name
        if (Test-Path $final) {
            Remove-Item $b.FullName -Recurse -Force -ErrorAction SilentlyContinue   # swap completed; backup is stale
        } else {
            Move-Item $b.FullName $final -ErrorAction SilentlyContinue              # swap died mid-way; recover
            Write-Host "  Recovered profile '$name' from an interrupted save." -ForegroundColor Yellow
        }
    }
    # Staging dirs are only complete for an instant before the swap; a leftover
    # one is an incomplete attempt. The real profile (or its recovered backup) is
    # authoritative, so discard it.
    foreach ($s in Get-ChildItem $Store -Directory -Filter '.staging-*' -ErrorAction SilentlyContinue) {
        Remove-Item $s.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Run at startup. If a previous switch was interrupted mid-copy, the live store
# may be inconsistent; re-apply the profile that was being restored.
function Repair-IfInterrupted {
    if (-not (Test-Path $SwitchMarker)) { return }
    $target = Read-Text $SwitchMarker
    Write-Host ""
    Write-Host "  A previous switch to '$target' was interrupted - the live session may be" -ForegroundColor Yellow
    Write-Host "  inconsistent. Repairing by re-applying that profile..." -ForegroundColor Yellow
    Write-Host ""

    if (-not $target -or -not (Test-ProfileComplete $target)) {
        Remove-Item $SwitchMarker -Force -ErrorAction SilentlyContinue
        Write-Warning "Cannot auto-repair: profile '$target' is missing or incomplete. If Claude asks you to sign in, that is why."
        return
    }
    $procs = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Warning "Close Claude, then re-run this tool to finish repairing the interrupted switch."
        return
    }
    Restore-Profile -ProfileName $target   # rewrites the marker and clears it on success
    Write-Host "  Repair complete - live session restored to '$target'." -ForegroundColor Green
}

# --- Commands ----------------------------------------------------------------

if (-not (Test-Path $Store)) { New-Item -ItemType Directory -Path $Store -Force | Out-Null }

# Recover from interrupted operations before doing anything else. Repair-Saves
# is cheap and always safe (it only touches orphaned .backup-*/.staging-* dirs);
# the interrupted-switch repair takes the lock if it acts.
Repair-Saves
if ((Test-Path $SwitchMarker) -and $Command -notin @('save','switch')) {
    Enter-ProfileLock
    try { Repair-IfInterrupted } finally { Exit-ProfileLock }
}

# Guard messages are for humans. Without this, PowerShell renders every 'throw'
# as a RuntimeException with a stack trace and the message repeated twice.
try {

switch ($Command) {

    'doctor' {
        Write-Host ""
        Write-Host "  App data root : $AppRoot" -ForegroundColor Cyan
        Write-Host "  Config file   : $ClaudeJson"
        Write-Host "  Profile store : $Store"
        Write-Host ""
        $running = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
        if ($running) {
            Write-Host "  App running   : yes ($($running.Count) processes)" -ForegroundColor Yellow
        } else {
            Write-Host "  App running   : no"
        }
        if (Test-FileUnlocked $CookieDb) {
            Write-Host "  Cookie DB     : unlocked (safe to copy)"
        } else {
            Write-Host "  Cookie DB     : LOCKED - close the app before save/switch" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Source files:"
        foreach ($item in $Items) {
            $ok = Test-Path $item.Live
            $mark = '  MISSING'
            if ($ok) { $mark = '  ok     ' }
            $color = 'Red'
            if ($ok) { $color = 'Gray' }
            Write-Host ("  {0} {1,-16} {2}" -f $mark, $item.Stored, $item.Live) -ForegroundColor $color
        }
        Write-Host ""
        if (Test-Path $SwitchMarker) {
            Write-Host "  Interrupted switch pending repair -> '$(Read-Text $SwitchMarker)'" -ForegroundColor Yellow
            Write-Host "  (close Claude and run 'list' to auto-repair)" -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    'whoami' {
        $appUuid  = Get-AppAccountUuid
        $liveProf = Get-LiveProfile

        $label = '<unlabeled>'
        if ($liveProf) {
            $l = Get-ProfileLabel $liveProf
            if ($l) { $label = $l }
        }
        $shownProf = $liveProf
        if (-not $shownProf) { $shownProf = '<not saved as a profile>' }

        Write-Host ""
        Write-Host "  Claude Code account : $label" -ForegroundColor Cyan
        Write-Host "  Account UUID        : $appUuid"
        Write-Host "  Matching profile    : $shownProf"
        Write-Host ""
        Write-Host "  Identity comes from config.json. The email in .claude.json is" -ForegroundColor DarkGray
        Write-Host "  not reliable - it does not follow desktop account switches." -ForegroundColor DarkGray
        Write-Host "  This is the Claude CODE session; Chat/Cowork signs in separately." -ForegroundColor DarkGray
        Write-Host ""
    }

    'list' {
        $liveUuid = Get-AppAccountUuid
        $liveProf = Get-LiveProfile

        Write-Host ""
        $shownProf = $liveProf
        if (-not $shownProf) { $shownProf = '<no matching profile>' }
        Write-Host "  Live account : $(Get-ShortUuid $liveUuid)   (profile: $shownProf)" -ForegroundColor Cyan
        Write-Host ""

        $profiles = Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike '.*' }
        if (-not $profiles) {
            Write-Host "  No saved profiles yet." -ForegroundColor DarkGray
            Write-Host "  Save the account you're signed into now with:" -ForegroundColor DarkGray
            Write-Host "    .\claude-profile.ps1 save personal" -ForegroundColor DarkGray
            Write-Host ""
            break
        }

        Write-Host "  Saved profiles:"
        $anyUnlabeled = $false
        foreach ($p in $profiles) {
            $uuid  = Get-ProfileUuid $p.Name
            $label = Get-ProfileLabel $p.Name
            if (-not $label) { $label = '<unlabeled>'; $anyUnlabeled = $true }

            $state = 'ok'
            if (-not (Test-ProfileComplete $p.Name)) { $state = 'INCOMPLETE' }

            $prefix = '     '
            if ($p.Name -eq $liveProf) { $prefix = '   * ' }

            $color = 'Gray'
            if ($state -eq 'INCOMPLETE')    { $color = 'Red' }
            elseif ($p.Name -eq $liveProf)  { $color = 'Green' }

            Write-Host ("{0}{1,-12} {2,-26} {3,-12} {4}" -f `
                $prefix, $p.Name, $label, (Get-ShortUuid $uuid), $state) -ForegroundColor $color
        }
        Write-Host ""
        if ($anyUnlabeled) {
            Write-Host "  Name an account with:  .\claude-profile.ps1 label <profile> <text>" -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    'save' {
        if (-not $Name) { throw "Usage: .\claude-profile.ps1 save <name>" }
        if ($Name -like '.*') { throw "Profile names cannot start with a dot." }

        $email = Get-CurrentEmail
        if (-not $email) { throw "Not signed in - nothing to save. Sign into the app first." }

        # The footgun that produced two identical profiles: saving again without
        # signing out. Refuse unless explicitly overridden.
        if (-not $Force) {
            $uuid = Get-AppAccountUuid
            if (-not $uuid) { $uuid = Get-CurrentUuid }

            $clash = Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notlike '.*' -and $_.Name -ne $Name } |
                     Where-Object {
                         if ($uuid -and (Get-ProfileUuid $_.Name)) { (Get-ProfileUuid $_.Name) -eq $uuid }
                         else { (Get-ProfileAccount $_.Name) -eq $email }
                     }
            if ($clash) {
                throw ("Account '$email' is already saved as profile '$($clash[0].Name)'.`n" +
                       "The Claude Code session is still on this account.`n" +
                       "Note: switching accounts from the chat account menu does NOT switch Claude Code -`n" +
                       "you must switch on the Code side, then re-run this. Check with 'doctor'.`n" +
                       "(Use -Force only if you deliberately want two profiles on the same account.)")
            }
        }

        Enter-ProfileLock
        try {
            Repair-IfInterrupted
            Stop-ClaudeApp
            Save-Profile -ProfileName $Name
            Write-Text $Marker $Name
        } finally { Exit-ProfileLock }
    }

    'switch' {
        if (-not $Name) { throw "Usage: .\claude-profile.ps1 switch <name>" }
        if (-not (Test-Path (Join-Path $Store $Name))) {
            throw "No saved profile named '$Name'. Run 'list' to see what exists."
        }
        if (-not (Test-ProfileComplete $Name)) {
            throw "Profile '$Name' is incomplete. Re-save it while signed into that account."
        }

        if ((Get-CurrentProfile) -eq $Name) {
            Write-Host "Already on profile '$Name'." -ForegroundColor Yellow
            break
        }

        Enter-ProfileLock
        try {
            Repair-IfInterrupted

            # Read the outgoing profile AFTER repair. Repair-IfInterrupted can
            # re-apply an interrupted switch and rewrite the current-profile
            # marker, so a value captured earlier would name the wrong profile
            # and the checkpoint below would overwrite it with the wrong session.
            $cur = Get-CurrentProfile
            if ($cur -eq $Name) {
                Write-Host "Already on profile '$Name' after repair." -ForegroundColor Yellow
            } else {
                Stop-ClaudeApp

                # Re-save the outgoing profile first: tokens refresh during use,
                # and skipping this rolls that account back to a stale session.
                if ($cur -and (Test-Path (Join-Path $Store $cur))) {
                    Save-Profile -ProfileName $cur -Quiet
                    Write-Host "Checkpointed outgoing profile '$cur'." -ForegroundColor DarkGray
                } elseif (Get-CurrentEmail) {
                    Write-Warning "Current session belongs to no saved profile and will be replaced."
                }

                Restore-Profile -ProfileName $Name
            }
        } finally { Exit-ProfileLock }

        $acct = Get-ProfileAccount $Name
        if (-not $acct) { $acct = '<unknown>' }
        Write-Host "Switched to '$Name' -> $acct" -ForegroundColor Green

        if (-not $NoLaunch) {
            Start-Process "shell:AppsFolder\$Aumid"
            Write-Host "Relaunching Claude..." -ForegroundColor DarkGray
        }
    }

    'delete' {
        if (-not $Name) { throw "Usage: .\claude-profile.ps1 delete <name>" }
        $dir = Join-Path $Store $Name
        if (-not (Test-Path $dir)) { throw "No saved profile named '$Name'." }
        Remove-Item $dir -Recurse -Force
        if ((Get-CurrentProfile) -eq $Name) { Remove-Item $Marker -Force -ErrorAction SilentlyContinue }
        Write-Host "Deleted profile '$Name'." -ForegroundColor Green
    }

    'label' {
        if (-not $Name) { throw "Usage: .\claude-profile.ps1 label <profile> <text>" }
        $dir = Join-Path $Store $Name
        if (-not (Test-Path $dir)) { throw "No saved profile named '$Name'." }
        if (-not $NewName) {
            $existing = Get-ProfileLabel $Name
            if ($existing) { Write-Host "  $Name is labelled '$existing'." }
            else           { Write-Host "  $Name has no label. Set one: label $Name <text>" }
            break
        }
        Write-Text (Join-Path $dir 'label.txt') $NewName
        Write-Host "Labelled '$Name' as '$NewName' ($(Get-ShortUuid (Get-ProfileUuid $Name)))." -ForegroundColor Green
    }

    'rename' {
        if (-not $Name -or -not $NewName) { throw "Usage: .\claude-profile.ps1 rename <old> <new>" }
        if ($NewName -like '.*') { throw "Profile names cannot start with a dot." }

        $from = Join-Path $Store $Name
        $to   = Join-Path $Store $NewName
        if (-not (Test-Path $from)) { throw "No saved profile named '$Name'." }
        if (Test-Path $to)          { throw "A profile named '$NewName' already exists." }

        # Purely a rename in the profile store -- no session files are touched,
        # so the app can stay open.
        Move-Item $from $to
        if ((Get-CurrentProfile) -eq $Name) { Write-Text $Marker $NewName }
        Write-Host "Renamed '$Name' -> '$NewName'." -ForegroundColor Green
    }
}

} catch {
    Write-Host ""
    foreach ($line in ($_.Exception.Message -split "`n")) {
        Write-Host "  $($line.TrimEnd())" -ForegroundColor Red
    }
    Write-Host ""
    exit 1
}
