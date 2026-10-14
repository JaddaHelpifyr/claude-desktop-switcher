$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-switcher-timer.ps1')

$script:ThreadExceptions = New-Object 'System.Collections.Generic.List[System.Exception]'
$threadExceptionHandler = [System.Threading.ThreadExceptionEventHandler] {
    param($sender, $eventArgs)
    $script:ThreadExceptions.Add($eventArgs.Exception)
}
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException($threadExceptionHandler)

$script:RefreshTickCount = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 10
$state = @{ Stopped = $false }
$handler = { if (-not $state.Stopped) { $script:RefreshTickCount++ } }
$timer.Add_Tick($handler)
$timer.Start()
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 10
    [System.Windows.Forms.Application]::DoEvents()
}

if ($script:ThreadExceptions.Count -gt 0) {
    throw "ASSERTION FAILED: timer callback raised $($script:ThreadExceptions[0].GetType().FullName): $($script:ThreadExceptions[0].Message)"
}
if ($script:RefreshTickCount -lt 2) { throw 'ASSERTION FAILED: WinForms timer did not tick.' }

Stop-SwitcherRefreshTimer -Timer $timer -Handler $handler -State $state
$stoppedCount = $script:RefreshTickCount
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 10
    [System.Windows.Forms.Application]::DoEvents()
}

if (-not $state.Stopped) { throw 'ASSERTION FAILED: timer state was not marked stopped.' }
if ($script:RefreshTickCount -ne $stoppedCount) { throw 'ASSERTION FAILED: timer callback ran after cleanup.' }
[System.Windows.Forms.Application]::remove_ThreadException($threadExceptionHandler)

$gui = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-switcher-gui.ps1'))
if ($gui -notmatch '\$form\.Add_FormClosing\(') { throw 'ASSERTION FAILED: GUI does not clean up on FormClosing.' }
if ($gui -notmatch '(?s)try\s*\{\s*\[void\]\$form\.ShowDialog\(\)\s*\}\s*finally') {
    throw 'ASSERTION FAILED: GUI does not clean up in a ShowDialog finally block.'
}

Write-Host 'PASS: WinForms refresh timer stops, detaches, disposes, and ignores queued callbacks.' -ForegroundColor Green
