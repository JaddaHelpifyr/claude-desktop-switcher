<#
.SYNOPSIS
    Move Claude Code session transcripts between your two accounts.

.DESCRIPTION
    The desktop app stores session INDEX entries per account:

        <AppRoot>\claude-code-sessions\<accountUuid>\<orgUuid>\local_<id>.json

    but the actual transcripts live in a shared, account-agnostic tree:

        ~\.claude\projects\<encoded-cwd>\<cliSessionId>.jsonl

    So a session only needs its small index file copied into the other
    account's folder -- the conversation itself is already visible to both.
    Nothing is moved or deleted; the session appears under both accounts.

    Commands:
      .\claude-sessions.ps1 accounts
      .\claude-sessions.ps1 list <account>
      .\claude-sessions.ps1 copy <sessionId> <targetAccount>

    <account> accepts a profile name from claude-profile.ps1 (resolved via that
    profile's stored config.json, NOT its display label, which is unreliable)
    or any unambiguous account-UUID prefix.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('accounts', 'list', 'copy')]
    [string]$Command = 'accounts',

    [Parameter(Position = 1)]
    [string]$Arg1,

    [Parameter(Position = 2)]
    [string]$Arg2
)

$ErrorActionPreference = 'Stop'

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

$AppRoot      = Resolve-AppRoot
$SessionsRoot = Join-Path $AppRoot 'claude-code-sessions'
$ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$Store        = Join-Path $env:USERPROFILE '.claude-profiles'

# Index of every transcript on disk: cliSessionId -> project folder. This is the
# shared tree, so it is identical no matter which account is signed in.
function Get-TranscriptIndex {
    $map = @{}
    if (-not (Test-Path $ProjectsRoot)) { return $map }
    foreach ($f in Get-ChildItem $ProjectsRoot -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
        $map[$f.BaseName] = $f.Directory.Name
    }
    return $map
}

function Get-SessionRecords {
    param([string]$AccountUuid)

    $acctDir = Join-Path $SessionsRoot $AccountUuid
    if (-not (Test-Path $acctDir)) { return @() }

    $out = @()
    foreach ($orgDir in Get-ChildItem $acctDir -Directory -ErrorAction SilentlyContinue) {
        foreach ($f in Get-ChildItem $orgDir.FullName -Filter 'local_*.json' -ErrorAction SilentlyContinue) {
            try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            $out += [pscustomobject]@{
                SessionId = $j.sessionId
                CliId     = $j.cliSessionId
                Title     = $j.title
                Cwd       = $j.cwd
                LastAt    = $j.lastActivityAt
                Org       = $orgDir.Name
                Path      = $f.FullName
            }
        }
    }
    return $out
}

function Get-AccountSummary {
    $rows = @()
    foreach ($d in Get-ChildItem $SessionsRoot -Directory -ErrorAction SilentlyContinue) {
        $recs = Get-SessionRecords -AccountUuid $d.Name
        # The org that actually holds this account's sessions.
        $org = $null
        if ($recs) { $org = ($recs | Group-Object Org | Sort-Object Count -Descending | Select-Object -First 1).Name }
        $rows += [pscustomobject]@{
            Uuid     = $d.Name
            Sessions = $recs.Count
            Org      = $org
            Profiles = (Get-ProfilesForUuid $d.Name) -join ','
        }
    }
    return $rows
}

# Map profile -> account by reading the config.json each profile would RESTORE.
# The account.txt label is sourced from .claude.json, which does not track the
# desktop app's account, so it cannot be trusted here.
function Get-ProfilesForUuid {
    param([string]$Uuid)
    $names = @()
    if (-not (Test-Path $Store)) { return $names }
    foreach ($p in Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue) {
        if ($p.Name -like '.*') { continue }
        $cfg = Join-Path $p.FullName 'config.json'
        if (-not (Test-Path $cfg)) { continue }
        try {
            $c = Get-Content $cfg -Raw | ConvertFrom-Json
            if ($c.lastKnownAccountUuid -eq $Uuid) { $names += $p.Name }
        } catch { }
    }
    return $names
}

function Resolve-Account {
    param([string]$Ref)
    if (-not $Ref) { throw "Specify an account: a profile name or an account-UUID prefix." }

    $profDir = Join-Path $Store $Ref
    $profCfg = Join-Path $profDir 'config.json'
    if (Test-Path $profCfg) {
        $c = Get-Content $profCfg -Raw | ConvertFrom-Json
        if ($c.lastKnownAccountUuid) { return $c.lastKnownAccountUuid }
    }

    $hits = @(Get-ChildItem $SessionsRoot -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like "$Ref*" })
    if ($hits.Count -eq 1) { return $hits[0].Name }
    if ($hits.Count -gt 1) { throw "'$Ref' is ambiguous - matches $($hits.Count) accounts." }
    throw "No profile or account matches '$Ref'. Run 'accounts' to see the options."
}

function Format-When {
    param($Ms)
    if (-not $Ms) { return '' }
    try { return ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Ms).LocalDateTime).ToString('MM-dd HH:mm') }
    catch { return '' }
}

try {

switch ($Command) {

    'accounts' {
        Write-Host ""
        Write-Host "  Accounts with Claude Code sessions:" -ForegroundColor Cyan
        Write-Host ""
        foreach ($r in Get-AccountSummary) {
            $prof = $r.Profiles
            if (-not $prof) { $prof = '<no profile>' }
            Write-Host ("    {0}  {1,4} sessions   profile: {2}" -f $r.Uuid, $r.Sessions, $prof)
            if ($r.Org) { Write-Host ("      org {0}" -f $r.Org) -ForegroundColor DarkGray }
        }
        Write-Host ""
        Write-Host "  Transcripts on disk: $((Get-TranscriptIndex).Count) (shared by all accounts)" -ForegroundColor DarkGray
        Write-Host ""
    }

    'list' {
        $uuid = Resolve-Account $Arg1
        $tx   = Get-TranscriptIndex
        $recs = Get-SessionRecords -AccountUuid $uuid | Sort-Object { [int64]$_.LastAt } -Descending

        Write-Host ""
        Write-Host "  Account $uuid - $($recs.Count) session(s)" -ForegroundColor Cyan
        Write-Host ""
        if (-not $recs) { Write-Host "  (none)" -ForegroundColor DarkGray; Write-Host ""; break }

        foreach ($r in $recs) {
            $has = '  '
            if (-not $tx.ContainsKey($r.CliId)) { $has = ' !' }
            $title = $r.Title
            if (-not $title) { $title = '<untitled>' }
            if ($title.Length -gt 44) { $title = $title.Substring(0, 41) + '...' }
            Write-Host ("  {0} {1,-11} {2,-44} {3}" -f $has, (Format-When $r.LastAt), $title, $r.SessionId)
        }
        Write-Host ""
        Write-Host "  '!' = transcript file missing; copying it would give an empty session." -ForegroundColor DarkGray
        Write-Host ""
    }

    'copy' {
        if (-not $Arg1 -or -not $Arg2) { throw "Usage: .\claude-sessions.ps1 copy <sessionId> <targetAccount>" }

        # Find the session under whichever account currently owns it.
        $src = $null
        foreach ($d in Get-ChildItem $SessionsRoot -Directory -ErrorAction SilentlyContinue) {
            $hit = Get-SessionRecords -AccountUuid $d.Name |
                   Where-Object { $_.SessionId -eq $Arg1 -or $_.SessionId -like "*$Arg1*" }
            if ($hit) { $src = @($hit)[0]; $srcAccount = $d.Name; break }
        }
        if (-not $src) { throw "No session matching '$Arg1'. Run 'list <account>' to find its id." }

        $dstAccount = Resolve-Account $Arg2
        if ($dstAccount -eq $srcAccount) { throw "Session is already under account $dstAccount." }

        # Target org: the one that already holds that account's sessions.
        $dstRecs = Get-SessionRecords -AccountUuid $dstAccount
        $dstOrg = $null
        if ($dstRecs) { $dstOrg = ($dstRecs | Group-Object Org | Sort-Object Count -Descending | Select-Object -First 1).Name }
        if (-not $dstOrg) {
            $dirs = @(Get-ChildItem (Join-Path $SessionsRoot $dstAccount) -Directory -ErrorAction SilentlyContinue)
            if ($dirs.Count -eq 1) { $dstOrg = $dirs[0].Name }
            else { throw "Cannot determine which org folder to use under $dstAccount. Open a session on that account first." }
        }

        $tx = Get-TranscriptIndex
        if (-not $tx.ContainsKey($src.CliId)) {
            Write-Warning "No transcript found for cliSessionId $($src.CliId) - the copied session may open empty."
        }

        $dstDir  = Join-Path (Join-Path $SessionsRoot $dstAccount) $dstOrg
        $dstFile = Join-Path $dstDir (Split-Path $src.Path -Leaf)
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        if (Test-Path $dstFile) { throw "That session already exists under the target account." }

        Copy-Item $src.Path $dstFile -Force

        Write-Host ""
        Write-Host "  Copied session to account $dstAccount" -ForegroundColor Green
        Write-Host "    title      : $($src.Title)"
        Write-Host "    cwd        : $($src.Cwd)"
        Write-Host "    transcript : $($src.CliId) ($($tx[$src.CliId]))"
        Write-Host "    org folder : $dstOrg"
        Write-Host ""
        Write-Host "  The original is untouched - the session now appears under both accounts." -ForegroundColor DarkGray
        if (Get-Process -Name 'claude' -ErrorAction SilentlyContinue) {
            Write-Host "  Restart Claude for it to show up in the session list." -ForegroundColor Yellow
        }
        Write-Host ""
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
