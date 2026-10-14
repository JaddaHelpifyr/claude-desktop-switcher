function Stop-SwitcherRefreshTimer {
    param(
        [System.Windows.Forms.Timer]$Timer,
        [scriptblock]$Handler,
        [hashtable]$State
    )

    if (-not $Timer -or -not $State -or $State.Stopped) { return }

    $State.Stopped = $true
    $Timer.Stop()
    if ($Handler) { $Timer.Remove_Tick($Handler) }
    $Timer.Dispose()
}
