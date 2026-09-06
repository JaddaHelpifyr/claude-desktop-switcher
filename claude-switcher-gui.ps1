<#
.SYNOPSIS
    Windows GUI for the Claude account switcher, session mover, and limit watcher.

.DESCRIPTION
    Wraps claude-profile.ps1, claude-sessions.ps1 and claude-autoswitch.ps1 so
    none of them need to be driven from a command line.

    Reads state directly from disk (config.json, the profile store, the session
    index) and shells out to the three scripts only to perform actions, so the
    lists stay accurate even if something changes them outside this window.
#>

#requires -version 5
[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'

# --- Locate the tools --------------------------------------------------------

$ScriptDir     = $PSScriptRoot
$ProfileScript = Join-Path $ScriptDir 'claude-profile.ps1'
$SessionScript = Join-Path $ScriptDir 'claude-sessions.ps1'
$AutoScript    = Join-Path $ScriptDir 'claude-autoswitch.ps1'

foreach ($s in @($ProfileScript, $SessionScript, $AutoScript)) {
    if (-not (Test-Path $s)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Missing: $s`n`nKeep all four scripts in the same folder.",
            'Claude Switcher', 'OK', 'Error')
        return
    }
}

# --- State readers (mirror the scripts; never trust cached labels) -----------

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
    foreach ($c in @(
        (Join-Path $env:APPDATA 'Claude'),
        (Join-Path $env:LOCALAPPDATA "Packages\$fam\LocalCache\Roaming\Claude"))) {
        if (Test-Path (Join-Path $c 'config.json')) { return $c }
    }
    return $null
}

$AppRoot      = Resolve-AppRoot
$Store        = Join-Path $env:USERPROFILE '.claude-profiles'
$SessionsRoot = if ($AppRoot) { Join-Path $AppRoot 'claude-code-sessions' } else { $null }
$ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$LogFile      = Join-Path $Store 'autoswitch.log'
$StateFile    = Join-Path $Store 'autoswitch-cooldowns.json'

function Read-Trimmed {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $t = [System.IO.File]::ReadAllText($Path)
        return $t.Trim([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x0A)
    } catch { return $null }
}

function Get-LiveUuid {
    if (-not $AppRoot) { return $null }
    try { return (Get-Content (Join-Path $AppRoot 'config.json') -Raw | ConvertFrom-Json).lastKnownAccountUuid }
    catch { return $null }
}

function Get-Profiles {
    $out = @()
    if (-not (Test-Path $Store)) { return $out }
    $items = @('Local State','Network','Local Storage','Session Storage','config.json','claude.json')
    foreach ($p in Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue) {
        if ($p.Name -like '.*') { continue }
        $uuid = $null
        $cfg = Join-Path $p.FullName 'config.json'
        if (Test-Path $cfg) {
            try { $uuid = (Get-Content $cfg -Raw | ConvertFrom-Json).lastKnownAccountUuid } catch { }
        }
        if (-not $uuid) { $uuid = Read-Trimmed (Join-Path $p.FullName 'account-uuid.txt') }
        $complete = $true
        foreach ($i in $items) { if (-not (Test-Path (Join-Path $p.FullName $i))) { $complete = $false } }
        $label = Read-Trimmed (Join-Path $p.FullName 'label.txt')
        if (-not $label) { $label = '<unlabeled>' }
        $out += [pscustomobject]@{ Name = $p.Name; Label = $label; Uuid = $uuid; Complete = $complete }
    }
    return $out
}

function Get-SessionsFor {
    param([string]$Uuid)
    $out = @()
    if (-not $SessionsRoot -or -not $Uuid) { return $out }
    $dir = Join-Path $SessionsRoot $Uuid
    if (-not (Test-Path $dir)) { return $out }
    foreach ($org in Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue) {
        foreach ($f in Get-ChildItem $org.FullName -Filter 'local_*.json' -ErrorAction SilentlyContinue) {
            try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            $out += [pscustomobject]@{
                SessionId = $j.sessionId
                CliId     = $j.cliSessionId
                Title     = $(if ($j.title) { $j.title } else { '<untitled>' })
                Cwd       = $j.cwd
                LastAt    = $j.lastActivityAt
            }
        }
    }
    return $out | Sort-Object { [int64]$_.LastAt } -Descending
}

# Authoritative: the watcher holds this mutex for its whole life. Process-list
# scraping is only used to report the PID, and is allowed to fail without
# turning a running watcher into a reported "stopped".
function Test-WatcherRunning {
    $m = $null
    try {
        $open = [System.Threading.Mutex]::TryOpenExisting('Global\ClaudeAutoSwitchWatcher', [ref]$m)
        if ($m) { $m.Dispose() }
        return $open
    } catch { return $false }
}

# Returns an object, never a bare array: PowerShell unrolls a one-element array
# on return (so .Count reads wrong) and an empty one to $null (which would be
# indistinguishable from a query failure).
function Get-WatcherProcs {
    try {
        $p = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
               Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*claude-autoswitch*' -and $_.CommandLine -match '\srun(\s|$)' })
        return [pscustomobject]@{ Ok = $true;  Procs = $p }
    } catch {
        return [pscustomobject]@{ Ok = $false; Procs = @() }
    }
}

function Format-Epoch {
    param($Ms, [switch]$Seconds)
    if (-not $Ms) { return '' }
    try {
        if ($Seconds) { return ([DateTimeOffset]::FromUnixTimeSeconds([int64]$Ms).LocalDateTime).ToString('MM-dd HH:mm') }
        return ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Ms).LocalDateTime).ToString('MM-dd HH:mm')
    } catch { return '' }
}

function Get-ShortUuid {
    param([string]$U)
    if (-not $U) { return '<unknown>' }
    if ($U.Length -le 8) { return $U }
    return $U.Substring(0,8) + '...'
}

# --- Form scaffolding --------------------------------------------------------

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Claude Account Switcher'
$form.Size            = New-Object System.Drawing.Size(940, 700)
$form.StartPosition   = 'CenterScreen'
$form.MinimumSize     = New-Object System.Drawing.Size(820, 600)

$header               = New-Object System.Windows.Forms.Label
$header.Location      = New-Object System.Drawing.Point(14, 12)
$header.Size          = New-Object System.Drawing.Size(760, 22)
$header.Font          = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($header)

$btnRefresh           = New-Object System.Windows.Forms.Button
$btnRefresh.Text      = 'Refresh'
$btnRefresh.Location  = New-Object System.Drawing.Point(800, 8)
$btnRefresh.Size      = New-Object System.Drawing.Size(110, 26)
$btnRefresh.Anchor    = 'Top,Right'
$form.Controls.Add($btnRefresh)

$tabs                 = New-Object System.Windows.Forms.TabControl
$tabs.Location        = New-Object System.Drawing.Point(12, 42)
$tabs.Size            = New-Object System.Drawing.Size(898, 400)
$tabs.Anchor          = 'Top,Bottom,Left,Right'
$form.Controls.Add($tabs)

$outBox               = New-Object System.Windows.Forms.TextBox
$outBox.Location      = New-Object System.Drawing.Point(12, 452)
$outBox.Size          = New-Object System.Drawing.Size(898, 200)
$outBox.Multiline     = $true
$outBox.ScrollBars    = 'Vertical'
$outBox.ReadOnly      = $true
$outBox.Font          = New-Object System.Drawing.Font('Consolas', 9)
$outBox.Anchor        = 'Bottom,Left,Right'
$form.Controls.Add($outBox)

function Add-Output {
    param([string]$Text)
    if (-not $Text) { return }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $outBox.AppendText("[$stamp] " + $Text.TrimEnd() + "`r`n")
    $outBox.SelectionStart = $outBox.TextLength
    $outBox.ScrollToCaret()
}

# $Arguments is splatted as an array, which binds POSITIONALLY -- a '-Switch'
# string in there arrives as a value and fails to bind. Named parameters and
# switches must go through $Named, which splats as a hashtable.
function Invoke-Tool {
    param([string]$Script, [string[]]$Arguments, [hashtable]$Named)
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:Busy = $true          # keep the auto-refresh timer out of the way
    try {
        if ($null -eq $Named) { $Named = @{} }
        $res = & $Script @Arguments @Named *>&1 | Out-String
        Add-Output $res
    } catch {
        Add-Output ("ERROR: " + $_.Exception.Message)
    } finally {
        $script:Busy = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Show-Ask {
    param([string]$Prompt, [string]$Default = '')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Claude Switcher'; $dlg.Size = New-Object System.Drawing.Size(420, 150)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt; $lbl.Location = New-Object System.Drawing.Point(12, 15)
    $lbl.Size = New-Object System.Drawing.Size(390, 20); $dlg.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $Default; $tb.Location = New-Object System.Drawing.Point(12, 40)
    $tb.Size = New-Object System.Drawing.Size(385, 24); $dlg.Controls.Add($tb)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Location = New-Object System.Drawing.Point(225, 75)
    $ok.Size = New-Object System.Drawing.Size(80, 26); $ok.DialogResult = 'OK'; $dlg.Controls.Add($ok)

    $ca = New-Object System.Windows.Forms.Button
    $ca.Text = 'Cancel'; $ca.Location = New-Object System.Drawing.Point(315, 75)
    $ca.Size = New-Object System.Drawing.Size(80, 26); $ca.DialogResult = 'Cancel'; $dlg.Controls.Add($ca)

    $dlg.AcceptButton = $ok; $dlg.CancelButton = $ca
    if ($dlg.ShowDialog($form) -eq 'OK') { return $tb.Text.Trim() }
    return $null
}

# =============================== Tab: Profiles ===============================

$tabProfiles          = New-Object System.Windows.Forms.TabPage
$tabProfiles.Text     = 'Accounts'
$tabs.Controls.Add($tabProfiles)

$lvProfiles           = New-Object System.Windows.Forms.ListView
$lvProfiles.Location  = New-Object System.Drawing.Point(10, 12)
$lvProfiles.Size      = New-Object System.Drawing.Size(640, 330)
$lvProfiles.View      = 'Details'
$lvProfiles.FullRowSelect = $true
$lvProfiles.MultiSelect   = $false
$lvProfiles.GridLines     = $true
$lvProfiles.Anchor        = 'Top,Bottom,Left,Right'
[void]$lvProfiles.Columns.Add('', 28)
[void]$lvProfiles.Columns.Add('Profile', 110)
[void]$lvProfiles.Columns.Add('Account', 220)
[void]$lvProfiles.Columns.Add('UUID', 110)
[void]$lvProfiles.Columns.Add('State', 90)
$tabProfiles.Controls.Add($lvProfiles)

$lblProfHint          = New-Object System.Windows.Forms.Label
$lblProfHint.Location = New-Object System.Drawing.Point(662, 284)
$lblProfHint.Size     = New-Object System.Drawing.Size(214, 60)
$lblProfHint.Anchor   = 'Top,Right'
$lblProfHint.ForeColor = [System.Drawing.Color]::DimGray
$lblProfHint.Text     = "Double-click an account to switch to it.`r`n`r`nSwitching closes and reopens Claude."
$tabProfiles.Controls.Add($lblProfHint)

$profButtons = @(
    @{ Text = 'Switch to selected'; Y = 12  ; Name = 'switch' },
    @{ Text = 'Add account...';     Y = 48  ; Name = 'add'    },
    @{ Text = 'Save current as...'; Y = 84  ; Name = 'save'   },
    @{ Text = 'Rename...';          Y = 120 ; Name = 'rename' },
    @{ Text = 'Set label...';       Y = 156 ; Name = 'label'  },
    @{ Text = 'Delete...';          Y = 192 ; Name = 'delete' },
    @{ Text = 'Diagnostics';        Y = 238 ; Name = 'doctor' }
)
$profBtn = @{}
foreach ($b in $profButtons) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $b.Text
    $btn.Location = New-Object System.Drawing.Point(662, $b.Y)
    $btn.Size = New-Object System.Drawing.Size(214, 30)
    $btn.Anchor = 'Top,Right'
    $tabProfiles.Controls.Add($btn)
    $profBtn[$b.Name] = $btn
}

# =============================== Tab: Sessions ===============================

$tabSessions          = New-Object System.Windows.Forms.TabPage
$tabSessions.Text     = 'Sessions'
$tabs.Controls.Add($tabSessions)

$lblAcct              = New-Object System.Windows.Forms.Label
$lblAcct.Text         = 'Account:'
$lblAcct.Location     = New-Object System.Drawing.Point(10, 16)
$lblAcct.Size         = New-Object System.Drawing.Size(60, 20)
$tabSessions.Controls.Add($lblAcct)

$cbAccount            = New-Object System.Windows.Forms.ComboBox
$cbAccount.Location   = New-Object System.Drawing.Point(72, 12)
$cbAccount.Size       = New-Object System.Drawing.Size(300, 24)
$cbAccount.DropDownStyle = 'DropDownList'
$tabSessions.Controls.Add($cbAccount)

$lvSessions           = New-Object System.Windows.Forms.ListView
$lvSessions.Location  = New-Object System.Drawing.Point(10, 46)
$lvSessions.Size      = New-Object System.Drawing.Size(640, 296)
$lvSessions.View      = 'Details'
$lvSessions.FullRowSelect = $true
$lvSessions.MultiSelect   = $false
$lvSessions.GridLines     = $true
$lvSessions.Anchor        = 'Top,Bottom,Left,Right'
[void]$lvSessions.Columns.Add('Last active', 100)
[void]$lvSessions.Columns.Add('Title', 300)
[void]$lvSessions.Columns.Add('Transcript', 90)
[void]$lvSessions.Columns.Add('Session id', 140)
$tabSessions.Controls.Add($lvSessions)

$btnCopySession       = New-Object System.Windows.Forms.Button
$btnCopySession.Text  = 'Copy to other account'
$btnCopySession.Location = New-Object System.Drawing.Point(662, 46)
$btnCopySession.Size  = New-Object System.Drawing.Size(214, 30)
$btnCopySession.Anchor = 'Top,Right'
$tabSessions.Controls.Add($btnCopySession)

$lblSessHint          = New-Object System.Windows.Forms.Label
$lblSessHint.Location = New-Object System.Drawing.Point(662, 84)
$lblSessHint.Size     = New-Object System.Drawing.Size(214, 150)
$lblSessHint.Anchor   = 'Top,Right'
$lblSessHint.ForeColor = [System.Drawing.Color]::DimGray
$lblSessHint.Text     = "Transcripts are shared between accounts - copying only adds the session to the other account's list. The original stays put.`r`n`r`nRestart Claude for a copied session to appear."
$tabSessions.Controls.Add($lblSessHint)

# =============================== Tab: Watcher ================================

$tabWatcher           = New-Object System.Windows.Forms.TabPage
$tabWatcher.Text      = 'Auto-switch'
$tabs.Controls.Add($tabWatcher)

# =============================== Tab: Warming ================================

$tabWarm            = New-Object System.Windows.Forms.TabPage
$tabWarm.Text       = 'Warming'
$tabs.Controls.Add($tabWarm)

$lblWarmIntro          = New-Object System.Windows.Forms.Label
$lblWarmIntro.Location = New-Object System.Drawing.Point(12, 10)
$lblWarmIntro.Size     = New-Object System.Drawing.Size(870, 34)
$lblWarmIntro.ForeColor = [System.Drawing.Color]::DimGray
$lblWarmIntro.Text     = "A 5-hour window opens on first use. Warming sends one tiny prompt per account so the window is already ticking when you sit down." +
                         "`r`nIt runs headlessly as each account, so it never switches accounts or interrupts what you are doing."
$tabWarm.Controls.Add($lblWarmIntro)

$chkWarm            = New-Object System.Windows.Forms.CheckBox
$chkWarm.Text       = 'Keep usage windows warm'
$chkWarm.Location   = New-Object System.Drawing.Point(12, 50)
$chkWarm.Size       = New-Object System.Drawing.Size(220, 24)
$tabWarm.Controls.Add($chkWarm)

$lblWarmIdle        = New-Object System.Windows.Forms.Label
$lblWarmIdle.Text   = 'only when idle for'
$lblWarmIdle.Location = New-Object System.Drawing.Point(240, 54)
$lblWarmIdle.Size   = New-Object System.Drawing.Size(110, 20)
$tabWarm.Controls.Add($lblWarmIdle)

$numWarmIdle        = New-Object System.Windows.Forms.NumericUpDown
$numWarmIdle.Location = New-Object System.Drawing.Point(352, 50)
$numWarmIdle.Size   = New-Object System.Drawing.Size(55, 24)
$numWarmIdle.Minimum = 0
$numWarmIdle.Maximum = 600
$numWarmIdle.Value  = 20
$tabWarm.Controls.Add($numWarmIdle)

$lblWarmIdle2       = New-Object System.Windows.Forms.Label
$lblWarmIdle2.Text  = 'min (0 = any time)'
$lblWarmIdle2.Location = New-Object System.Drawing.Point(412, 54)
$lblWarmIdle2.Size  = New-Object System.Drawing.Size(120, 20)
$tabWarm.Controls.Add($lblWarmIdle2)

$lblWarmStag        = New-Object System.Windows.Forms.Label
$lblWarmStag.Text   = 'stagger accounts by'
$lblWarmStag.Location = New-Object System.Drawing.Point(540, 54)
$lblWarmStag.Size   = New-Object System.Drawing.Size(120, 20)
$tabWarm.Controls.Add($lblWarmStag)

$numWarmStag        = New-Object System.Windows.Forms.NumericUpDown
$numWarmStag.Location = New-Object System.Drawing.Point(662, 50)
$numWarmStag.Size   = New-Object System.Drawing.Size(60, 24)
$numWarmStag.Minimum = 0
$numWarmStag.Maximum = 600
$numWarmStag.Value  = 150
$tabWarm.Controls.Add($numWarmStag)

$lblWarmStag2       = New-Object System.Windows.Forms.Label
$lblWarmStag2.Text  = 'min'
$lblWarmStag2.Location = New-Object System.Drawing.Point(728, 54)
$lblWarmStag2.Size  = New-Object System.Drawing.Size(40, 20)
$tabWarm.Controls.Add($lblWarmStag2)

$lvWarm             = New-Object System.Windows.Forms.ListView
$lvWarm.Location    = New-Object System.Drawing.Point(12, 86)
$lvWarm.Size        = New-Object System.Drawing.Size(640, 250)
$lvWarm.View        = 'Details'
$lvWarm.FullRowSelect = $true
$lvWarm.MultiSelect = $false
$lvWarm.GridLines   = $true
$lvWarm.Anchor      = 'Top,Bottom,Left,Right'
[void]$lvWarm.Columns.Add('Profile', 90)
[void]$lvWarm.Columns.Add('CLI signed in as', 215)
[void]$lvWarm.Columns.Add('Window', 215)
[void]$lvWarm.Columns.Add('Last warmed', 110)
$tabWarm.Controls.Add($lvWarm)

$warmButtons = @(
    @{ Text = 'Refresh';      Y = 86;  Name = 'refresh' },
    @{ Text = 'Warm now';     Y = 124; Name = 'now'     },
    @{ Text = 'Sign in...';   Y = 168; Name = 'login'   },
    @{ Text = 'Sign out';     Y = 206; Name = 'logout'  }
)
$warmBtn = @{}
foreach ($b in $warmButtons) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $b.Text
    $btn.Location = New-Object System.Drawing.Point(664, $b.Y)
    $btn.Size = New-Object System.Drawing.Size(212, 30)
    $btn.Anchor = 'Top,Right'
    $tabWarm.Controls.Add($btn)
    $warmBtn[$b.Name] = $btn
}

$lblWarmHint          = New-Object System.Windows.Forms.Label
$lblWarmHint.Location = New-Object System.Drawing.Point(664, 246)
$lblWarmHint.Size     = New-Object System.Drawing.Size(212, 90)
$lblWarmHint.Anchor   = 'Top,Right'
$lblWarmHint.ForeColor = [System.Drawing.Color]::DimGray
$lblWarmHint.Text     = "Each account needs its own one-time sign-in. If your browser is already signed into the other account, use a private window."
$tabWarm.Controls.Add($lblWarmHint)

$lblWatch             = New-Object System.Windows.Forms.Label
$lblWatch.Location    = New-Object System.Drawing.Point(12, 14)
$lblWatch.Size        = New-Object System.Drawing.Size(620, 24)
$lblWatch.Font        = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$tabWatcher.Controls.Add($lblWatch)

$lblCooldown          = New-Object System.Windows.Forms.Label
$lblCooldown.Location = New-Object System.Drawing.Point(12, 42)
$lblCooldown.Size     = New-Object System.Drawing.Size(620, 60)
$tabWatcher.Controls.Add($lblCooldown)

$chkDryRun            = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text       = 'Dry run (detect and log, never actually switch)'
$chkDryRun.Location   = New-Object System.Drawing.Point(12, 112)
$chkDryRun.Size       = New-Object System.Drawing.Size(400, 24)
$chkDryRun.Checked    = $true
$tabWatcher.Controls.Add($chkDryRun)

$chkFiveHour          = New-Object System.Windows.Forms.CheckBox
$chkFiveHour.Text     = 'Also switch on 5-hour limits (spends the weekly budget)'
$chkFiveHour.Location = New-Object System.Drawing.Point(12, 138)
$chkFiveHour.Size     = New-Object System.Drawing.Size(400, 24)
$tabWatcher.Controls.Add($chkFiveHour)

$lblMinWait          = New-Object System.Windows.Forms.Label
$lblMinWait.Text     = 'only if it resets more than'
$lblMinWait.Location = New-Object System.Drawing.Point(418, 142)
$lblMinWait.Size     = New-Object System.Drawing.Size(158, 20)
$tabWatcher.Controls.Add($lblMinWait)

$numMinWait          = New-Object System.Windows.Forms.NumericUpDown
$numMinWait.Location = New-Object System.Drawing.Point(578, 138)
$numMinWait.Size     = New-Object System.Drawing.Size(54, 24)
$numMinWait.Minimum  = 0
$numMinWait.Maximum  = 300
$numMinWait.Value    = 30
$tabWatcher.Controls.Add($numMinWait)

$lblMinWait2          = New-Object System.Windows.Forms.Label
$lblMinWait2.Text     = 'min away'
$lblMinWait2.Location = New-Object System.Drawing.Point(636, 142)
$lblMinWait2.Size     = New-Object System.Drawing.Size(70, 20)
$tabWatcher.Controls.Add($lblMinWait2)

$lblCarry             = New-Object System.Windows.Forms.Label
$lblCarry.Text        = 'On failover, carry over sessions touched in the last'
$lblCarry.Location    = New-Object System.Drawing.Point(12, 168)
$lblCarry.Size        = New-Object System.Drawing.Size(300, 20)
$tabWatcher.Controls.Add($lblCarry)

$numCarry             = New-Object System.Windows.Forms.NumericUpDown
$numCarry.Location    = New-Object System.Drawing.Point(316, 164)
$numCarry.Size        = New-Object System.Drawing.Size(60, 24)
$numCarry.Minimum     = 5
$numCarry.Maximum     = 1440
$numCarry.Value       = 60
$tabWatcher.Controls.Add($numCarry)

$lblCarry2            = New-Object System.Windows.Forms.Label
$lblCarry2.Text       = 'min'
$lblCarry2.Location   = New-Object System.Drawing.Point(382, 168)
$lblCarry2.Size       = New-Object System.Drawing.Size(40, 20)
$tabWatcher.Controls.Add($lblCarry2)

$watchButtons = @(
    @{ Text = 'Start watcher';        X = 12;  Y = 206; Name = 'start'    },
    @{ Text = 'Stop watcher';         X = 176; Y = 206; Name = 'stop'     },
    @{ Text = 'Run on login';         X = 12;  Y = 244; Name = 'install'  },
    @{ Text = "Don't run on login";   X = 176; Y = 244; Name = 'uninstall'},
    @{ Text = 'Open log';             X = 12;  Y = 288; Name = 'log'      },
    @{ Text = 'Clear cooldowns';      X = 176; Y = 288; Name = 'reset'    },
    @{ Text = 'Replay past limits';   X = 340; Y = 288; Name = 'test'     },
    @{ Text = 'Self-test';            X = 340; Y = 244; Name = 'selftest' }
)
$watchBtn = @{}
foreach ($b in $watchButtons) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $b.Text
    $btn.Location = New-Object System.Drawing.Point($b.X, $b.Y)
    $btn.Size = New-Object System.Drawing.Size(156, 30)
    $tabWatcher.Controls.Add($btn)
    $watchBtn[$b.Name] = $btn
}

# --- Refresh -----------------------------------------------------------------

$script:Profiles = @()

function Update-All {
    $live = Get-LiveUuid
    $script:Profiles = @(Get-Profiles)

    $liveProf = $null
    foreach ($p in $script:Profiles) { if ($p.Uuid -eq $live) { $liveProf = $p } }

    if ($liveProf) {
        $header.Text = "Signed in: $($liveProf.Label)   ($($liveProf.Name))"
    } elseif ($live) {
        $header.Text = "Signed in: $(Get-ShortUuid $live)   (no matching profile)"
    } else {
        $header.Text = 'Signed in: unknown - is the desktop app installed?'
    }

    $lvProfiles.Items.Clear()
    foreach ($p in $script:Profiles) {
        $mark = ''
        if ($p.Uuid -eq $live) { $mark = [char]0x25CF }
        $state = 'ok'
        if (-not $p.Complete) { $state = 'INCOMPLETE' }
        $it = New-Object System.Windows.Forms.ListViewItem($mark)
        [void]$it.SubItems.Add($p.Name)
        [void]$it.SubItems.Add($p.Label)
        [void]$it.SubItems.Add((Get-ShortUuid $p.Uuid))
        [void]$it.SubItems.Add($state)
        $it.Tag = $p
        if (-not $p.Complete) { $it.ForeColor = [System.Drawing.Color]::Firebrick }
        elseif ($p.Uuid -eq $live) { $it.ForeColor = [System.Drawing.Color]::SeaGreen }
        [void]$lvProfiles.Items.Add($it)
    }

    # Sessions tab account list
    $sel = $cbAccount.SelectedIndex
    $cbAccount.Items.Clear()
    foreach ($p in $script:Profiles) { [void]$cbAccount.Items.Add("$($p.Name)  -  $($p.Label)") }
    if ($cbAccount.Items.Count -gt 0) {
        if ($sel -ge 0 -and $sel -lt $cbAccount.Items.Count) { $cbAccount.SelectedIndex = $sel }
        else { $cbAccount.SelectedIndex = 0 }
    }

    # Watcher state
    $running = Test-WatcherRunning
    $q       = Get-WatcherProcs
    $list    = @($q.Procs)
    if ($running) {
        $ids = '?'
        if ($list.Count -gt 0) { $ids = ($list | ForEach-Object { $_.ProcessId }) -join ', ' }

        # Stale if any script file was modified after the watcher process started
        # -- it's running code older than what's on disk.
        $stale = $false
        $newestPs1 = (Get-ChildItem $ScriptDir -Filter '*.ps1' -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($newestPs1 -and $list.Count -gt 0) {
            $oldestStart = ($list | ForEach-Object { $_.CreationDate } | Sort-Object | Select-Object -First 1)
            if ($oldestStart -and $newestPs1.LastWriteTime -gt $oldestStart) { $stale = $true }
        }

        if ($stale) {
            $lblWatch.Text = "Watcher: RUNNING but OUTDATED (PID $ids) - Stop then Start to update"
            $lblWatch.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        } else {
            $lblWatch.Text = "Watcher: RUNNING  (PID $ids)"
            $lblWatch.ForeColor = [System.Drawing.Color]::SeaGreen
        }
    } elseif (-not $q.Ok) {
        $lblWatch.Text = 'Watcher: UNKNOWN - could not query processes'
        $lblWatch.ForeColor = [System.Drawing.Color]::DarkGoldenrod
    } else {
        $lblWatch.Text = 'Watcher: stopped'
        $lblWatch.ForeColor = [System.Drawing.Color]::Firebrick
    }

    $cdText = 'No accounts are rate limited.'
    if (Test-Path $StateFile) {
        try {
            $cd = Get-Content $StateFile -Raw | ConvertFrom-Json
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $lines = @()
            foreach ($pr in $cd.PSObject.Properties) {
                if ([int64]$pr.Value -gt $now) {
                    $nm = (Get-ShortUuid $pr.Name)
                    foreach ($p in $script:Profiles) { if ($p.Uuid -eq $pr.Name) { $nm = $p.Label } }
                    $lines += "$nm  limited until $(Format-Epoch $pr.Value -Seconds)"
                }
            }
            if ($lines.Count -gt 0) { $cdText = ($lines -join "`r`n") }
        } catch { }
    }
    $lblCooldown.Text = $cdText

    # Baseline for the auto-refresh timer, so it only fires on a change made
    # outside this window (e.g. the watcher failing over) rather than after
    # every refresh we do ourselves.
    $script:LastSeenUuid    = $live
    $script:LastSeenWatcher = $running

    Update-Sessions
}

function Update-Sessions {
    $lvSessions.Items.Clear()
    if ($cbAccount.SelectedIndex -lt 0) { return }
    $p = $script:Profiles[$cbAccount.SelectedIndex]
    if (-not $p) { return }

    $tx = @{}
    if (Test-Path $ProjectsRoot) {
        foreach ($f in Get-ChildItem $ProjectsRoot -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
            $tx[$f.BaseName] = $true
        }
    }

    foreach ($s in Get-SessionsFor $p.Uuid) {
        $it = New-Object System.Windows.Forms.ListViewItem((Format-Epoch $s.LastAt))
        [void]$it.SubItems.Add($s.Title)
        $has = 'ok'
        if (-not $tx.ContainsKey([string]$s.CliId)) { $has = 'MISSING' }
        [void]$it.SubItems.Add($has)
        [void]$it.SubItems.Add($s.SessionId)
        $it.Tag = $s
        if ($has -eq 'MISSING') { $it.ForeColor = [System.Drawing.Color]::Firebrick }
        [void]$lvSessions.Items.Add($it)
    }
}

# --- Wiring ------------------------------------------------------------------

# Warming rows are expensive: each one shells out to claude.exe for auth status.
# So this refreshes only on demand (tab selected, Refresh, or after an action) --
# never from the 3s auto-refresh timer.
function Update-Warm {
    $lvWarm.Items.Clear()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $out = & $AutoScript warm-status *>&1 | Out-String
        $lines = $out -split "`r?`n"
        $inList = $false
        $status = @{}
        foreach ($l in $lines) {
            if ($l -match 'Per-account CLI login:') { $inList = $true; continue }
            if ($inList) {
                if ($l -match '^\s*$') { $inList = $false; continue }
                if ($l -match '^\s{4}(\S+)\s+(.+?)\s*$') { $status[$Matches[1]] = $Matches[2] }
            }
        }
        $decision = @()
        $inDec = $false
        foreach ($l in $lines) {
            if ($l -match '^\s*Decision:') { $inDec = $true; continue }
            if ($inDec -and $l.Trim()) { $decision += $l.Trim() }
        }

        foreach ($p in $script:Profiles) {
            $cli = if ($status.ContainsKey($p.Name)) { $status[$p.Name] } else { '<unknown>' }
            # warm-status phrasing is written for a console; render it compactly
            # here so the column reads at a glance instead of truncating.
            $win = '?'
            foreach ($d in $decision) {
                if ($d -match "^$([regex]::Escape($p.Name))\s*:\s*(.+)$") {
                    $raw = $Matches[1]
                    $win = switch -Regex ($raw) {
                        'window open \(active (.+?)\)' { "open - last used $($Matches[1])"; break }
                        'window closed'                { 'CLOSED - will warm';             break }
                        'rate limited until (.+?) -'   { "rate limited until $($Matches[1])"; break }
                        default                        { $raw }
                    }
                }
            }
            $warmed = ''
            try {
                $ws = Get-Content (Join-Path $Store 'autoswitch-warm.json') -Raw | ConvertFrom-Json
                $v = $ws.PSObject.Properties[$p.Uuid]
                if ($v) { $warmed = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$v.Value).LocalDateTime).ToString('MM-dd HH:mm') }
            } catch { }

            $it = New-Object System.Windows.Forms.ListViewItem($p.Name)
            [void]$it.SubItems.Add($cli)
            [void]$it.SubItems.Add($win)
            [void]$it.SubItems.Add($warmed)
            $it.Tag = $p
            if ($cli -like 'WRONG ACCOUNT*') { $it.ForeColor = [System.Drawing.Color]::Firebrick }
            elseif ($cli -like 'not logged in*') { $it.ForeColor = [System.Drawing.Color]::DarkGoldenrod }
            [void]$lvWarm.Items.Add($it)
        }
    } catch {
        Add-Output ("warming status failed: " + $_.Exception.Message)
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Get-SelectedWarmProfile {
    if ($lvWarm.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select an account first.', 'Claude Switcher', 'OK', 'Information')
        return $null
    }
    return $lvWarm.SelectedItems[0].Tag
}

$btnRefresh.Add_Click({ Update-All; if ($tabs.SelectedTab -eq $tabWarm) { Update-Warm } })

# Populate the warming tab the first time it is opened, not on every refresh.
$script:WarmLoaded = $false
$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $tabWarm -and -not $script:WarmLoaded) {
        $script:WarmLoaded = $true
        Update-Warm
    }
})

$warmBtn['refresh'].Add_Click({ Update-Warm })

$warmBtn['now'].Add_Click({
    $p = Get-SelectedWarmProfile
    if (-not $p) { return }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Send a warm-up prompt as '$($p.Name)' now?`n`nThis spends a small amount of that account's quota and opens its 5-hour window.",
        'Claude Switcher', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $AutoScript @('warm-now', $p.Name)
    Update-Warm
})

$warmBtn['login'].Add_Click({
    $p = Get-SelectedWarmProfile
    if (-not $p) { return }
    [void][System.Windows.Forms.MessageBox]::Show(
        ("A console window will open to sign in for '$($p.Name)'.`n`n" +
         "Sign in as the account this profile holds. If your browser is already signed " +
         "into the other account it will approve that one instead - use a private window " +
         "with the URL the console prints.`n`n" +
         "If you are given a code, paste it into that console window."),
        'Sign in for warming', 'OK', 'Information')
    # A visible console: the CLI may prompt for a pasted code, which needs stdin.
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-Command',
        "cd '$ScriptDir'; .\claude-autoswitch.ps1 warm-login $($p.Name)"
    ) -WindowStyle Normal
    Add-Output "Opened a sign-in window for '$($p.Name)'. Press Refresh here when it finishes."
})

$warmBtn['logout'].Add_Click({
    $p = Get-SelectedWarmProfile
    if (-not $p) { return }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Sign the CLI out for '$($p.Name)'?`n`nWarming will stop working for that account until you sign in again.",
        'Claude Switcher', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $AutoScript @('warm-logout', $p.Name)
    Update-Warm
})
$cbAccount.Add_SelectedIndexChanged({ Update-Sessions })

function Get-SelectedProfile {
    if ($lvProfiles.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select an account first.', 'Claude Switcher', 'OK', 'Information')
        return $null
    }
    return $lvProfiles.SelectedItems[0].Tag
}

function Invoke-SwitchToSelected {
    $p = Get-SelectedProfile
    if (-not $p) { return }
    if (-not $p.Complete) {
        [void][System.Windows.Forms.MessageBox]::Show("Profile '$($p.Name)' is incomplete and cannot be restored. Re-save it while signed into that account.", 'Claude Switcher', 'OK', 'Warning')
        return
    }
    if ($p.Uuid -eq (Get-LiveUuid)) {
        [void][System.Windows.Forms.MessageBox]::Show("Already signed in as $($p.Label).", 'Claude Switcher', 'OK', 'Information')
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Switch to '$($p.Name)' ($($p.Label))?`n`nThis closes Claude and reopens it.",
        'Claude Switcher', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $ProfileScript @('switch', $p.Name)
    Update-All
}

$profBtn['switch'].Add_Click({ Invoke-SwitchToSelected })
$lvProfiles.Add_DoubleClick({ Invoke-SwitchToSelected })

# Guided flow for signing in a second account and capturing it as a profile.
# The app has no multi-account support, so the only way to add one is to sign
# out, sign in as the other account, and save what that leaves behind.
$profBtn['add'].Add_Click({
    $name = Show-Ask 'Short profile name for the new account (e.g. work):'
    if (-not $name) { return }
    if ($name -like '.*') {
        [void][System.Windows.Forms.MessageBox]::Show('Profile names cannot start with a dot.', 'Claude Switcher', 'OK', 'Warning')
        return
    }
    foreach ($p in $script:Profiles) {
        if ($p.Name -eq $name) {
            [void][System.Windows.Forms.MessageBox]::Show("A profile named '$name' already exists.", 'Claude Switcher', 'OK', 'Warning')
            return
        }
    }

    $before = Get-LiveUuid
    Start-Process ('shell:AppsFolder\' + (Get-ClaudeAumid))

    $r = [System.Windows.Forms.MessageBox]::Show(
        ("Claude is opening.`n`n" +
         "1. Open the account menu (bottom left)`n" +
         "2. Choose Log out`n" +
         "3. Sign in as the account you want to add`n`n" +
         "Then click OK here. Cancel abandons this."),
        'Add an account', 'OKCancel', 'Information')
    if ($r -ne 'OK') { Add-Output 'Add account: cancelled.'; return }

    $after = Get-LiveUuid
    if ($after -and $before -and $after -eq $before) {
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            ("Claude Code still reports the same account.`n`n" +
             "Signing out only on the Chat side does not move Claude Code. " +
             "Save anyway?`n`n(The save will refuse if the account really has not changed.)"),
            'Add an account', 'YesNo', 'Warning')
        if ($r2 -ne 'Yes') { Add-Output 'Add account: account unchanged, nothing saved.'; return }
    }

    Invoke-Tool $ProfileScript @('save', $name)
    Update-All

    $exists = $false
    foreach ($p in Get-Profiles) { if ($p.Name -eq $name) { $exists = $true } }
    if ($exists) {
        $lbl = Show-Ask "Saved. Display name for this account:" ''
        if ($lbl) { Invoke-Tool $ProfileScript @('label', $name, $lbl) }
        Update-All
    }
})

$profBtn['save'].Add_Click({
    $n = Show-Ask 'Save the currently signed-in account as which profile name?'
    if (-not $n) { return }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Save current session as '$n'?`n`nThis closes Claude.", 'Claude Switcher', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $ProfileScript @('save', $n)
    Update-All
})

$profBtn['rename'].Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    $n = Show-Ask "New name for '$($p.Name)':" $p.Name
    if (-not $n -or $n -eq $p.Name) { return }
    Invoke-Tool $ProfileScript @('rename', $p.Name, $n)
    Update-All
})

$profBtn['label'].Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    $d = $p.Label
    if ($d -eq '<unlabeled>') { $d = '' }
    $n = Show-Ask "Account name to display for '$($p.Name)':" $d
    if (-not $n) { return }
    Invoke-Tool $ProfileScript @('label', $p.Name, $n)
    Update-All
})

$profBtn['delete'].Add_Click({
    $p = Get-SelectedProfile
    if (-not $p) { return }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Delete profile '$($p.Name)'?`n`nThe saved session for $($p.Label) is removed. You would have to sign into that account again to recreate it.",
        'Claude Switcher', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $ProfileScript @('delete', $p.Name)
    Update-All
})

$profBtn['doctor'].Add_Click({ Invoke-Tool $ProfileScript @('doctor') })

$btnCopySession.Add_Click({
    if ($lvSessions.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a session first.', 'Claude Switcher', 'OK', 'Information')
        return
    }
    if ($script:Profiles.Count -lt 2) {
        [void][System.Windows.Forms.MessageBox]::Show('You need two saved profiles to move a session between accounts.', 'Claude Switcher', 'OK', 'Information')
        return
    }
    $s = $lvSessions.SelectedItems[0].Tag
    $src = $script:Profiles[$cbAccount.SelectedIndex]
    $dst = $null
    foreach ($p in $script:Profiles) { if ($p.Name -ne $src.Name) { $dst = $p; break } }
    if (-not $dst) { return }

    $r = [System.Windows.Forms.MessageBox]::Show(
        "Copy `"$($s.Title)`" to $($dst.Label)?`n`nThe original stays on $($src.Label). Restart Claude to see it.",
        'Claude Switcher', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Invoke-Tool $SessionScript @('copy', $s.SessionId, $dst.Name)
    Update-Sessions
})

$watchBtn['start'].Add_Click({
    if (Test-WatcherRunning) {
        [void][System.Windows.Forms.MessageBox]::Show('A watcher is already running.', 'Claude Switcher', 'OK', 'Information')
        return
    }
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$AutoScript,'run')
    if ($chkDryRun.Checked)   { $a += '-DryRun' }
    if ($chkFiveHour.Checked) { $a += '-IncludeFiveHour'; $a += '-MinFiveHourWaitMinutes'; $a += [string][int]$numMinWait.Value }
    $a += '-CarryOverMinutes'; $a += [string][int]$numCarry.Value
    if ($chkWarm.Checked) {
        $a += '-WarmWindows'
        $a += '-WarmIdleMinutes';    $a += [string][int]$numWarmIdle.Value
        $a += '-WarmStaggerMinutes'; $a += [string][int]$numWarmStag.Value
    }
    Start-Process powershell.exe -ArgumentList $a
    Add-Output 'Started watcher (hidden).'
    Start-Sleep -Milliseconds 1200
    Update-All
})

$watchBtn['stop'].Add_Click({
    Invoke-Tool $AutoScript @('stop')
    Update-All
})

$watchBtn['install'].Add_Click({
    $n = @{}
    if ($chkDryRun.Checked)   { $n['DryRun'] = $true }
    if ($chkFiveHour.Checked) { $n['IncludeFiveHour'] = $true; $n['MinFiveHourWaitMinutes'] = [int]$numMinWait.Value }
    $n['CarryOverMinutes'] = [int]$numCarry.Value
    if ($chkWarm.Checked) {
        $n['WarmWindows']        = $true
        $n['WarmIdleMinutes']    = [int]$numWarmIdle.Value
        $n['WarmStaggerMinutes'] = [int]$numWarmStag.Value
    }
    Invoke-Tool $AutoScript @('install-startup') $n
    # install-startup rewrites the shortcut, which drops the custom icon.
    $ico = Join-Path $ScriptDir 'claude-switcher.ico'
    if (Test-Path $ico) {
        try {
            $s = (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLnk)
            $s.IconLocation = "$ico,0"; $s.Save()
        } catch { }
    }
})

$watchBtn['uninstall'].Add_Click({ Invoke-Tool $AutoScript @('uninstall-startup') })

$watchBtn['log'].Add_Click({
    if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile }
    else { Add-Output 'No log file yet - the watcher has not logged anything.' }
})

$watchBtn['reset'].Add_Click({
    Invoke-Tool $AutoScript @('reset')
    Update-All
})

$watchBtn['test'].Add_Click({ Invoke-Tool $AutoScript @('test') })
$watchBtn['selftest'].Add_Click({ Invoke-Tool $AutoScript @('selftest') })

# --- Tooltips ----------------------------------------------------------------

$tip                = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay   = 20000     # these are long; give people time to read
$tip.InitialDelay   = 400
$tip.ReshowDelay    = 200
$tip.ShowAlways     = $true

$tip.SetToolTip($btnRefresh, 'Re-read accounts, sessions and watcher state from disk. Use this if something changed outside this window.')

$tip.SetToolTip($profBtn['switch'], "Sign the desktop app into the selected account.`nCloses Claude and reopens it. Same as double-clicking the row.")
$tip.SetToolTip($profBtn['add'],    "Guided setup for another account: opens Claude so you can log out and sign in as the new one, then saves that session as a profile.")
$tip.SetToolTip($profBtn['save'],   "Capture the account you are signed into RIGHT NOW as a new profile.`nCloses Claude briefly. Refuses if that account is already saved.")
$tip.SetToolTip($profBtn['rename'], 'Change the profile short name. Does not touch the account or the saved session.')
$tip.SetToolTip($profBtn['label'],  'Set the display name in the Account column. Cosmetic only - the UUID is the real identity.')
$tip.SetToolTip($profBtn['delete'], 'Remove the saved profile. You would have to sign into that account again to recreate it.')
$tip.SetToolTip($profBtn['doctor'], 'Show resolved paths, whether Claude is running, and whether each session file is readable.')
$tip.SetToolTip($lvProfiles,        'Double-click an account to switch to it. The green dot is the account currently signed in.')

$tip.SetToolTip($cbAccount,      "Choose which account's session list to show.")
$tip.SetToolTip($btnCopySession, "Add the selected conversation to the other account's list.`nThe original stays put - both accounts read the same transcript file.`nRestart Claude to see it appear.")
$tip.SetToolTip($lvSessions,     "Sessions belonging to the chosen account. 'MISSING' means the transcript file is gone, so copying it would open empty.")

$tip.SetToolTip($chkDryRun,   'Detect and log rate limits but never actually switch. Leave this on until you have seen it fire correctly once.')
$tip.SetToolTip($chkFiveHour, "Also fail over on 5-hour limits.`nOff by default: it spends the other account's WEEKLY budget to skip a few hours' wait.")
$tip.SetToolTip($numMinWait,  "Only switch on a 5-hour limit if its reset is at least this many minutes away.`nA limit that clears in 10 minutes is cheaper to wait out. Default 30.")

$tip.SetToolTip($watchBtn['start'],     'Start the watcher now, hidden, using the checkboxes above. Only one can run at a time.')
$tip.SetToolTip($watchBtn['stop'],      'Stop the running watcher, including one that was started at login.')
$tip.SetToolTip($watchBtn['install'],   'Create a Startup entry so the watcher launches hidden at every login, using the checkboxes above.')
$tip.SetToolTip($watchBtn['uninstall'], 'Remove the Startup entry. Does NOT stop a watcher that is already running.')
$tip.SetToolTip($watchBtn['log'],       'Open autoswitch.log in Notepad. It lives in .claude-profiles, next to your saved profiles.')
$tip.SetToolTip($watchBtn['reset'],     "Forget which accounts are rate limited.`nDoes NOT grant capacity - if an account is still limited, the watcher will switch to it and be refused again.")
$tip.SetToolTip($watchBtn['test'],      'Replay past rate-limit records found in your transcripts and show what the watcher would do with each. Changes nothing.')
$tip.SetToolTip($watchBtn['selftest'],  'Run synthetic limits through the detector to prove it still works after an edit or app update. Changes nothing.')

# --- Go ----------------------------------------------------------------------

# Reflect what the login entry is actually configured with. Without this the
# boxes always open on dry run, so pressing "Run on login" from a fresh window
# would silently revert a live setup back to dry run.
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Auto-Switch.lnk'
if (Test-Path $StartupLnk) {
    try {
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLnk)
        $chkDryRun.Checked   = [bool]($sc.Arguments -match '-DryRun')
        $chkFiveHour.Checked = [bool]($sc.Arguments -match '-IncludeFiveHour')
        if ($sc.Arguments -match '-MinFiveHourWaitMinutes\s+(\d+)') { $numMinWait.Value = [int]$Matches[1] }
        # Every flag must round-trip. Anything not read here is silently dropped
        # the next time Start watcher or Run on login is pressed.
        if ($sc.Arguments -match '-CarryOverMinutes\s+(\d+)')   { $numCarry.Value    = [int]$Matches[1] }
        $chkWarm.Checked = [bool]($sc.Arguments -match '-WarmWindows')
        if ($sc.Arguments -match '-WarmIdleMinutes\s+(\d+)')    { $numWarmIdle.Value = [int]$Matches[1] }
        if ($sc.Arguments -match '-WarmStaggerMinutes\s+(\d+)') { $numWarmStag.Value = [int]$Matches[1] }
    } catch { }
}

Update-All

# The watcher switches accounts from a separate process, so without this the
# Accounts tab keeps showing the old account (green dot on the one that just hit
# its limit) until Refresh is pressed. Poll only the two cheap authoritative
# signals - the live account UUID and the watcher mutex - and do a full refresh
# only when one of them actually changed. A full Update-All every few seconds
# would re-enumerate every transcript, which is far too heavy.
$script:Busy = $false
$refreshTimer          = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 3000
$refreshTimer.Add_Tick({
    if ($script:Busy) { return }
    try {
        $u = Get-LiveUuid
        $w = Test-WatcherRunning
        if ($u -ne $script:LastSeenUuid -or $w -ne $script:LastSeenWatcher) {
            $wasUuid = $script:LastSeenUuid
            Update-All          # this also re-baselines LastSeen*
            if ($u -ne $wasUuid) {
                $who = $null
                foreach ($p in $script:Profiles) { if ($p.Uuid -eq $u) { $who = $p.Label } }
                if (-not $who) { $who = Get-ShortUuid $u }
                Add-Output "Account changed outside this window - now on $who."
            } else {
                Add-Output 'Watcher state changed - refreshed.'
            }
        }
    } catch { }   # never let a transient read kill the timer
})
$refreshTimer.Start()

Add-Output 'Ready. Switching and saving both close Claude briefly.'
[void]$form.ShowDialog()
$refreshTimer.Stop()
$refreshTimer.Dispose()
