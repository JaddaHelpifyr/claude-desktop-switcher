<#
.SYNOPSIS
    Watch for weekly rate-limit rejections and fail over to the other account.

.DESCRIPTION
    Claude Code writes a 'quotaLimits' record into the active session transcript
    when a request is refused:

        {"status":"rejected","resetsAt":<epoch>,"rateLimitType":"seven_day",...}

    This tails the transcripts under ~\.claude\projects, and on a seven_day
    rejection it:

        1. records a cooldown for the current account, expiring at resetsAt
        2. copies the active session into the other account's index
        3. runs 'claude-profile.ps1 switch <other>' and relaunches the app

    The signal is REACTIVE. There is no local usage gauge - nothing on disk
    reports how much of the week you have spent, so a limit can only be observed
    after a request has already been refused. The turn that triggers it is lost
    and must be re-sent after the switch.

    Commands:
      .\claude-autoswitch.ps1 run       # start watching (foreground)
      .\claude-autoswitch.ps1 status    # cooldowns and profile mapping
      .\claude-autoswitch.ps1 reset     # clear all cooldowns
      .\claude-autoswitch.ps1 test      # replay history, act on nothing

    Options:
      -DryRun            detect and log, but never switch
      -IncludeFiveHour   also fail over on five_hour limits (off by default:
                         it spends the other account's WEEKLY budget to dodge a
                         few hours' wait)
      -IntervalSeconds   poll interval, default 5

    Run this from a normal PowerShell window. It force-closes Claude when it
    switches, which would kill a session started from inside the app.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'stop', 'status', 'reset', 'test', 'install-startup', 'uninstall-startup')]
    [string]$Command = 'status',

    [int]$IntervalSeconds = 5,
    [switch]$DryRun,
    [switch]$IncludeFiveHour,

    # With -IncludeFiveHour: only switch if the 5-hour window resets further
    # away than this. A limit that clears in ten minutes is not worth spending
    # the other account's WEEKLY budget on.
    [int]$MinFiveHourWaitMinutes = 30
)

$ErrorActionPreference = 'Stop'

# --- Paths -------------------------------------------------------------------

function Get-ClaudePackageFamily {
    foreach ($n in @('Claude', '*Claude*')) {
        try {
            $p = @(Get-AppxPackage -Name $n -ErrorAction Stop)
            if ($p.Count -gt 0) { return $p[0].PackageFamilyName }
        } catch { }
    }
    return 'Claude_pzs8sxrjxfjjc'   # last-known default
}

function Resolve-AppRoot {
    $fam = Get-ClaudePackageFamily
    $candidates = @(
        (Join-Path $env:APPDATA 'Claude'),
        (Join-Path $env:LOCALAPPDATA "Packages\$fam\LocalCache\Roaming\Claude")
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'claude-code-sessions')) { return $c }
    }
    throw ("Cannot find the Claude app data folder. Tried:`n  " + ($candidates -join "`n  "))
}

$AppRoot       = Resolve-AppRoot
$SessionsRoot  = Join-Path $AppRoot 'claude-code-sessions'
$AppConfig     = Join-Path $AppRoot 'config.json'
$ProjectsRoot  = Join-Path $env:USERPROFILE '.claude\projects'
$Store         = Join-Path $env:USERPROFILE '.claude-profiles'
$StateFile     = Join-Path $Store 'autoswitch-cooldowns.json'
$LogFile       = Join-Path $Store 'autoswitch.log'
$ProfileScript = Join-Path $PSScriptRoot 'claude-profile.ps1'
$ShortcutPath  = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Auto-Switch.lnk'
$isNew         = $false

if (-not (Test-Path $ProfileScript)) {
    throw "claude-profile.ps1 not found next to this script ($PSScriptRoot)."
}

# --- Logging -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $stamp = (Get-Date).ToString('MM-dd HH:mm:ss')
    Write-Host "  [$stamp] $Message" -ForegroundColor $Color
    try { Add-Content -Path $LogFile -Value "[$stamp] $Message" -Encoding utf8 } catch { }
}

# Windows toast. The watcher runs hidden and the app just closes mid-turn when
# it switches, so without this the only explanation of what happened is a log
# file. Uses PowerShell's own registered AppUserModelId, which lets an
# unpackaged script raise toasts without registering one of its own.
function Show-Toast {
    param([string]$Title, [string]$Body)
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [System.Security.SecurityElement]::Escape($Title)
        $b = [System.Security.SecurityElement]::Escape($Body)
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            (New-Object Windows.UI.Notifications.ToastNotification $doc))
    } catch {
        Write-Log "  (toast unavailable: $($_.Exception.Message))" 'DarkGray'
    }
}

# --- Identity ----------------------------------------------------------------

function Get-LiveAccountUuid {
    if (-not (Test-Path $AppConfig)) { return $null }
    try {
        $c = Get-Content $AppConfig -Raw | ConvertFrom-Json
        return $c.lastKnownAccountUuid
    } catch { return $null }
}

# name -> account uuid, read from the config.json each profile would restore.
function Get-ProfileMap {
    $map = @{}
    if (-not (Test-Path $Store)) { return $map }
    foreach ($p in Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue) {
        if ($p.Name -like '.*') { continue }
        $cfg = Join-Path $p.FullName 'config.json'
        if (-not (Test-Path $cfg)) { continue }
        try {
            $c = Get-Content $cfg -Raw | ConvertFrom-Json
            if ($c.lastKnownAccountUuid) { $map[$p.Name] = $c.lastKnownAccountUuid }
        } catch { }
    }
    return $map
}

function Get-ProfileLabel {
    param([string]$Name)
    $f = Join-Path (Join-Path $Store $Name) 'label.txt'
    if (-not (Test-Path $f)) { return $Name }
    $t = [System.IO.File]::ReadAllText($f)
    return $t.Trim([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x0A)
}

# --- Cooldowns ---------------------------------------------------------------

function Get-Cooldowns {
    if (-not (Test-Path $StateFile)) { return @{} }
    try {
        $o = Get-Content $StateFile -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = [int64]$p.Value }
        return $h
    } catch { return @{} }
}

function Set-Cooldowns {
    param([hashtable]$Map)
    # WriteAllText, not Set-Content -Encoding utf8: the latter emits a BOM, which
    # PowerShell tolerates on read but anything else parsing this file does not.
    [System.IO.File]::WriteAllText($StateFile, ($Map | ConvertTo-Json -Depth 3))
}

function Register-Cooldown {
    param([string]$Uuid, [int64]$ResetsAt, [string]$LimitType)
    $cool = Get-Cooldowns
    $cool[$Uuid] = $ResetsAt
    Set-Cooldowns $cool
    Write-Log "$LimitType limit hit on $($Uuid.Substring(0,8))... - cooling down until $(Format-Epoch $ResetsAt)" 'Yellow'
}

function Get-NowEpoch { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Format-Epoch {
    param($Epoch)
    if (-not $Epoch) { return '<none>' }
    return ([DateTimeOffset]::FromUnixTimeSeconds([int64]$Epoch).LocalDateTime).ToString('MM-dd HH:mm')
}

# --- Session copy ------------------------------------------------------------

# The transcript filename IS the cliSessionId, so it maps back to the app's
# index entry. Copying that entry makes the conversation resumable on the other
# account; the .jsonl itself is already shared between both.
function Copy-SessionToAccount {
    param([string]$CliSessionId, [string]$FromUuid, [string]$ToUuid)

    $srcFile = $null
    $srcDir  = Join-Path $SessionsRoot $FromUuid
    if (Test-Path $srcDir) {
        foreach ($orgDir in Get-ChildItem $srcDir -Directory -ErrorAction SilentlyContinue) {
            foreach ($f in Get-ChildItem $orgDir.FullName -Filter 'local_*.json' -ErrorAction SilentlyContinue) {
                try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
                if ($j.cliSessionId -eq $CliSessionId) { $srcFile = $f; break }
            }
            if ($srcFile) { break }
        }
    }
    if (-not $srcFile) { return "no index entry for cliSessionId $CliSessionId" }

    $dstAcct = Join-Path $SessionsRoot $ToUuid
    if (-not (Test-Path $dstAcct)) { return "target account has no session folder yet" }

    # Use the org folder that already holds that account's sessions.
    $best = $null; $bestCount = -1
    foreach ($orgDir in Get-ChildItem $dstAcct -Directory -ErrorAction SilentlyContinue) {
        $n = @(Get-ChildItem $orgDir.FullName -Filter 'local_*.json' -ErrorAction SilentlyContinue).Count
        if ($n -gt $bestCount) { $bestCount = $n; $best = $orgDir }
    }
    if (-not $best) { return "cannot determine target org folder" }

    $dstFile = Join-Path $best.FullName $srcFile.Name
    if (Test-Path $dstFile) { return "already present on target account" }

    Copy-Item $srcFile.FullName $dstFile -Force
    return "copied as $($srcFile.Name)"
}

# --- Failover ----------------------------------------------------------------

function Invoke-Failover {
    param([string]$CliSessionId, [int64]$ResetsAt, [string]$LimitType)

    $liveUuid = Get-LiveAccountUuid
    if (-not $liveUuid) { Write-Log "Cannot read the live account UUID - skipping." 'Red'; return }

    Register-Cooldown -Uuid $liveUuid -ResetsAt $ResetsAt -LimitType $LimitType
    $cool = Get-Cooldowns

    $now = Get-NowEpoch
    $map = Get-ProfileMap
    $target = $null
    foreach ($name in ($map.Keys | Sort-Object)) {
        $uuid = $map[$name]
        if ($uuid -eq $liveUuid) { continue }
        if ($cool.ContainsKey($uuid) -and $cool[$uuid] -gt $now) {
            Write-Log "  $name is also limited until $(Format-Epoch $cool[$uuid])" 'DarkGray'
            continue
        }
        $target = $name; break
    }

    if (-not $target) {
        Write-Log "No account available - every profile is rate limited. Still watching." 'Red'
        $soonest = ($cool.Values | Where-Object { $_ -gt $now } | Sort-Object | Select-Object -First 1)
        Show-Toast 'Claude: every account is rate limited' "Nothing to switch to. Earliest reset: $(Format-Epoch $soonest)."
        return
    }

    if ($DryRun) {
        Write-Log "DRY RUN: would switch to '$target' ($(Get-ProfileLabel $target))" 'Cyan'
        Show-Toast 'Claude switcher (dry run)' "$LimitType limit hit. Would have switched to $(Get-ProfileLabel $target)."
        return
    }

    # Belt: make the session visible on the target account by copying its index
    # entry, so it is there even if the app's own import below refuses.
    $result = Copy-SessionToAccount -CliSessionId $CliSessionId -FromUuid $liveUuid -ToUuid $map[$target]
    Write-Log "  session: $result"

    Write-Log "Switching to '$target' ($(Get-ProfileLabel $target))..." 'Cyan'
    & $ProfileScript switch $target -NoLaunch

    # Do NOT test $LASTEXITCODE here: claude-profile.ps1 only calls exit on
    # failure, so on success it stays null and '-eq 0' reports a false failure.
    # Ask the app which account it is actually on instead.
    Start-Sleep -Milliseconds 800
    $nowUuid = Get-LiveAccountUuid
    if ($nowUuid -ne $map[$target]) {
        if ($nowUuid -eq $liveUuid) { Write-Log "Switch did not take - still on the limited account." 'Red' }
        else { Write-Log "Switch finished but the account reads as $nowUuid - check with 'status'." 'Yellow' }
        Show-Toast 'Claude switcher: switch failed' 'Still on the rate-limited account. See autoswitch.log.'
        Start-Process ('shell:AppsFolder\' + (Get-ClaudeAumid))
        return
    }

    # Braces: relaunch through the app's own resume deep link so it opens
    # straight into the conversation instead of the session list. Verified in
    # the app bundle: claude://resume?session=<cliSessionId> -> importCliSession.
    # It rewrites the transcript (keeping a .pre-import copy) and files the
    # session as local_<cliSessionId>.
    Write-Log "  relaunching into the session via claude://resume" 'DarkGray'
    Start-Process "claude://resume?session=$CliSessionId"

    # If the import succeeded there are now two index entries for one transcript.
    # Drop ours; the app's is the canonical one.
    Start-Sleep -Seconds 6
    $tgtDir  = Join-Path $SessionsRoot $map[$target]
    $appMade = Join-Path (Join-Path $tgtDir '*') "local_$CliSessionId.json"
    if (Test-Path $appMade) {
        foreach ($f in Get-ChildItem $tgtDir -Recurse -Filter 'local_*.json' -ErrorAction SilentlyContinue) {
            if ($f.Name -eq "local_$CliSessionId.json") { continue }
            try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($j.cliSessionId -eq $CliSessionId) {
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "  app imported the session itself; removed duplicate $($f.Name)" 'DarkGray'
            }
        }
    } else {
        Write-Log "  app did not import via deep link; the copied entry stands (find it in the session list)" 'DarkGray'
    }

    $fromName = ($map.Keys | Where-Object { $map[$_] -eq $liveUuid } | Select-Object -First 1)
    $fromLabel = if ($fromName) { Get-ProfileLabel $fromName } else { $liveUuid.Substring(0,8) + '...' }
    Write-Log "Switched to $(Get-ProfileLabel $target). Re-send your last message." 'Green'
    Show-Toast "Claude: switched to $(Get-ProfileLabel $target)" "$LimitType limit on $fromLabel. Re-send your last message."
}

# --- Transcript tailing ------------------------------------------------------

function Get-TranscriptFiles {
    if (-not (Test-Path $ProjectsRoot)) { return @() }
    return Get-ChildItem $ProjectsRoot -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue
}

# Returns the new byte offset, having handed each COMPLETE line to the callback.
# A partial trailing line is left unconsumed so it is re-read once finished.
function Read-NewLines {
    param([string]$Path, [int64]$Offset, [scriptblock]$OnLine)

    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        if ($Offset -gt $fs.Length) { $Offset = 0 }   # file was truncated/rotated
        [void]$fs.Seek($Offset, 'Begin')
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd()
    } catch {
        return $Offset
    } finally {
        if ($fs) { $fs.Dispose() }
    }

    if (-not $text) { return $Offset }

    $lastNl = $text.LastIndexOf("`n")
    if ($lastNl -lt 0) { return $Offset }

    $complete = $text.Substring(0, $lastNl + 1)
    foreach ($line in ($complete -split "`n")) {
        if ($line.Trim()) { & $OnLine $line }
    }
    return $Offset + [System.Text.Encoding]::UTF8.GetByteCount($complete)
}

function Test-QuotaLine {
    param([string]$Line, [string]$CliSessionId)

    if ($Line -notlike '*"quotaLimits"*') { return }
    try { $o = $Line | ConvertFrom-Json } catch { return }
    $q = $o.quotaLimits
    if (-not $q -or $q.status -ne 'rejected') { return }

    $type = $q.rateLimitType
    if ($type -ne 'seven_day' -and -not ($IncludeFiveHour -and $type -eq 'five_hour')) {
        if ($type) { Write-Log "Ignoring $type rejection (use -IncludeFiveHour to act on these)." 'DarkGray' }
        return
    }
    if (-not $q.resetsAt) { Write-Log "Rejection had no resetsAt - schema may have changed." 'Red'; return }

    # A five-hour limit that clears soon is cheaper to wait out than to dodge:
    # switching spends the other account's WEEKLY budget. Record the cooldown so
    # 'status' shows it, but stay put.
    if ($type -eq 'five_hour') {
        $mins = [int](([int64]$q.resetsAt - (Get-NowEpoch)) / 60)
        if ($mins -lt $MinFiveHourWaitMinutes) {
            $live = Get-LiveAccountUuid
            if ($live) { Register-Cooldown -Uuid $live -ResetsAt ([int64]$q.resetsAt) -LimitType $type }
            Write-Log "  resets in $mins min (< $MinFiveHourWaitMinutes) - waiting rather than spending the other account's weekly budget." 'Yellow'
            Show-Toast 'Claude: 5-hour limit reached' "Resets in $mins min. Not switching - too short to be worth the other account's weekly budget."
            return
        }
    }

    Invoke-Failover -CliSessionId $CliSessionId -ResetsAt ([int64]$q.resetsAt) -LimitType $type
}

# --- Commands ----------------------------------------------------------------

try {

switch ($Command) {

    'status' {
        $live = Get-LiveAccountUuid
        $map  = Get-ProfileMap
        $cool = Get-Cooldowns
        $now  = Get-NowEpoch

        Write-Host ""
        Write-Host "  Live account : $live" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Profiles:"
        foreach ($name in ($map.Keys | Sort-Object)) {
            $uuid = $map[$name]
            $mark = '   '
            if ($uuid -eq $live) { $mark = ' * ' }
            $state = 'available'
            $color = 'Gray'
            if ($cool.ContainsKey($uuid) -and $cool[$uuid] -gt $now) {
                $state = "limited until $(Format-Epoch $cool[$uuid])"
                $color = 'Yellow'
            }
            Write-Host ("  {0}{1,-12} {2,-26} {3}" -f $mark, $name, (Get-ProfileLabel $name), $state) -ForegroundColor $color
        }
        Write-Host ""
        Write-Host "  Transcripts watched : $((Get-TranscriptFiles).Count)" -ForegroundColor DarkGray
        Write-Host "  Log                 : $LogFile" -ForegroundColor DarkGray
        Write-Host ""
    }

    'reset' {
        if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
        Write-Host "Cleared all cooldowns." -ForegroundColor Green
    }

    'test' {
        # Replay every historical rejection without acting, to prove the parser
        # matches what Claude Code actually writes.
        Write-Host ""
        Write-Host "  Replaying historical quotaLimits records (no action taken):" -ForegroundColor Cyan
        Write-Host ""
        $n = 0
        foreach ($f in Get-TranscriptFiles) {
            foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                if ($line -notlike '*"quotaLimits"*') { continue }
                try { $o = $line | ConvertFrom-Json } catch { continue }
                $q = $o.quotaLimits
                if (-not $q) { continue }
                $n++
                $act = 'ignored'
                if ($q.status -eq 'rejected' -and $q.rateLimitType -eq 'seven_day') { $act = 'WOULD SWITCH' }
                elseif ($q.status -eq 'rejected' -and $q.rateLimitType -eq 'five_hour') { $act = 'would switch (-IncludeFiveHour)' }
                Write-Host ("    {0,-10} {1,-10} resets {2}   {3}" -f `
                    $q.status, $q.rateLimitType, (Format-Epoch $q.resetsAt), $act)
            }
        }
        Write-Host ""
        Write-Host "  $n record(s) parsed." -ForegroundColor DarkGray
        Write-Host ""
    }

    'stop' {
        # The startup copy runs hidden, so there is no window to Ctrl+C. Find it
        # by command line instead. Matching on ' run' avoids killing this very
        # process, which also has 'claude-autoswitch' in its command line.
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                   Where-Object {
                       $_.ProcessId -ne $PID -and
                       $_.CommandLine -like '*claude-autoswitch*' -and
                       $_.CommandLine -match '\srun(\s|$)'
                   })

        Write-Host ""
        if (-not $procs) {
            Write-Host "  No watcher is running." -ForegroundColor Yellow
            Write-Host ""
            break
        }
        foreach ($p in $procs) {
            try {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                Write-Host "  Stopped watcher PID $($p.ProcessId)." -ForegroundColor Green
            } catch {
                Write-Host "  Could not stop PID $($p.ProcessId): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Write-Host ""
        Write-Host "  It will start again at your next login unless you also run:" -ForegroundColor DarkGray
        Write-Host "    .\claude-autoswitch.ps1 uninstall-startup" -ForegroundColor DarkGray
        Write-Host ""
    }

    'install-startup' {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($ShortcutPath)
        $sc.TargetPath = (Get-Command powershell.exe).Source

        $a = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" run"
        if ($DryRun)          { $a += ' -DryRun' }
        if ($IncludeFiveHour) { $a += ' -IncludeFiveHour' }
        if ($IncludeFiveHour -and $MinFiveHourWaitMinutes -ne 30) { $a += " -MinFiveHourWaitMinutes $MinFiveHourWaitMinutes" }
        if ($IntervalSeconds -ne 5) { $a += " -IntervalSeconds $IntervalSeconds" }

        $sc.Arguments        = $a
        $sc.WorkingDirectory = $PSScriptRoot
        $sc.WindowStyle      = 7          # minimized; -WindowStyle Hidden does the real work
        $sc.Description      = 'Claude weekly rate-limit auto-switch watcher'
        $sc.Save()

        Write-Host ""
        Write-Host "  Installed startup entry." -ForegroundColor Green
        Write-Host "    shortcut : $ShortcutPath"
        Write-Host "    runs     : $a" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Runs hidden at login. Watch it through the log:" -ForegroundColor DarkGray
        Write-Host "    $LogFile" -ForegroundColor DarkGray
        Write-Host ""
        if ($DryRun) {
            Write-Host "  DRY RUN is baked in. To go live later, re-run:" -ForegroundColor Yellow
            Write-Host "    .\claude-autoswitch.ps1 install-startup" -ForegroundColor Yellow
            Write-Host "  (without -DryRun; it overwrites the existing shortcut)" -ForegroundColor Yellow
            Write-Host ""
        }
    }

    'uninstall-startup' {
        if (Test-Path $ShortcutPath) {
            Remove-Item $ShortcutPath -Force
            Write-Host "Removed startup entry." -ForegroundColor Green
        } else {
            Write-Host "No startup entry installed." -ForegroundColor Yellow
        }
    }

    'run' {
        # One watcher only. Two would both detect the same rejection and race to
        # switch -- harmless in dry run, chaos in live mode.
        $mutex = New-Object System.Threading.Mutex($true, 'Global\ClaudeAutoSwitchWatcher', [ref]$isNew)
        if (-not $isNew) {
            Write-Host ""
            Write-Host "  Another watcher is already running - exiting." -ForegroundColor Yellow
            Write-Host ""
            exit 0
        }

        Write-Host ""
        Write-Host "  Watching for weekly rate-limit rejections." -ForegroundColor Cyan
        if ($DryRun)          { Write-Host "  DRY RUN - will detect but never switch." -ForegroundColor Yellow }
        if ($IncludeFiveHour) { Write-Host "  five_hour limits will ALSO trigger a switch." -ForegroundColor Yellow }
        Write-Host "  Ctrl+C to stop."
        Write-Host ""

        # Seed offsets at end-of-file so historical rejections are not replayed.
        $offsets = @{}
        foreach ($f in Get-TranscriptFiles) { $offsets[$f.FullName] = $f.Length }
        Write-Log "Watching $($offsets.Count) transcript(s). Live account: $(Get-LiveAccountUuid)"

        while ($true) {
            Start-Sleep -Seconds $IntervalSeconds
            foreach ($f in Get-TranscriptFiles) {
                $path = $f.FullName
                if (-not $offsets.ContainsKey($path)) {
                    # A session that started after we did: read it from the top.
                    $offsets[$path] = 0
                    Write-Log "New transcript: $($f.Name)" 'DarkGray'
                }
                if ($f.Length -eq $offsets[$path]) { continue }

                $cli = $f.BaseName
                $offsets[$path] = Read-NewLines -Path $path -Offset $offsets[$path] -OnLine {
                    param($line)
                    Test-QuotaLine -Line $line -CliSessionId $cli
                }
            }
        }
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
