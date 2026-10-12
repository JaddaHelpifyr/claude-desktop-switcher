$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-Sessions {
    param([string]$Command, [string[]]$Arguments)
    $processArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:SessScript, $Command) + $Arguments
    $output = @(& $script:PowerShell @processArgs 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Write-SessionIndex {
    param([string]$Path, [string]$SessionId, [string]$CliId, [bool]$IncludeCliId = $true)
    $cliField = if ($IncludeCliId) { '"cliSessionId":"' + $CliId + '",' } else { '' }
    $json = '{"sessionId":"' + $SessionId + '",' + $cliField + '"title":"Fixture ' + $SessionId + '","cwd":"C:\\fixture","lastActivityAt":1760000000000,"":null}'
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:SessScript = Join-Path $repoRoot 'claude-sessions.ps1'
$script:PowerShell = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
} else {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('claude-switcher-tests-' + [guid]::NewGuid().ToString('N'))
$oldAppData = $env:APPDATA
$oldLocalAppData = $env:LOCALAPPDATA
$oldUserProfile = $env:USERPROFILE

try {
    foreach ($path in @($script:SessScript, $script:PowerShell)) {
        Assert-True (Test-Path -LiteralPath $path) "Required path exists: $path"
    }

    foreach ($path in @((Join-Path $repoRoot 'claude-profile.ps1'), (Join-Path $repoRoot 'claude-switcher-gui.ps1'), (Join-Path $repoRoot 'claude-autoswitch.ps1'))) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "PowerShell syntax is valid: $path"
    }

    $appData = Join-Path $testRoot 'appdata'
    $userProfile = Join-Path $testRoot 'user'
    $appRoot = Join-Path $appData 'Claude'
    $sessionsRoot = Join-Path $appRoot 'claude-code-sessions'
    $profilesRoot = Join-Path $userProfile '.claude-profiles'
    $sourceUuid = '11111111-1111-4111-8111-111111111111'
    $targetUuid = '22222222-2222-4222-8222-222222222222'
    $sourceOrg = 'org-shared'
    $sourceDir = Join-Path (Join-Path $sessionsRoot $sourceUuid) $sourceOrg
    $targetRoot = Join-Path $sessionsRoot $targetUuid
    $targetDir = Join-Path $targetRoot $sourceOrg

    New-Item -ItemType Directory -Path $sourceDir, $targetDir, (Join-Path $targetRoot 'org-other'), (Join-Path $userProfile '.claude\projects\project-one'), (Join-Path $profilesRoot 'primary'), (Join-Path $profilesRoot 'secundary') -Force | Out-Null
    $env:APPDATA = $appData
    $env:LOCALAPPDATA = Join-Path $testRoot 'localappdata'
    $env:USERPROFILE = $userProfile
    [IO.File]::WriteAllText((Join-Path (Join-Path $profilesRoot 'primary') 'config.json'), '{"lastKnownAccountUuid":"' + $sourceUuid + '"}')
    [IO.File]::WriteAllText((Join-Path (Join-Path $profilesRoot 'secundary') 'config.json'), '{"lastKnownAccountUuid":"' + $targetUuid + '"}')

    Write-SessionIndex (Join-Path $sourceDir 'local_session-1.json') 'session-1' 'cli-one'
    Write-SessionIndex (Join-Path $sourceDir 'local_session-2.json') 'session-2' 'cli-missing'
    Write-SessionIndex (Join-Path $sourceDir 'local_session-3.json') 'session-3' '' $false
    [IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $userProfile '.claude\projects') 'project-one') 'cli-one.jsonl'), '{"fixture":true}')

    $sourceHashes = @{}
    Get-ChildItem $sourceDir -Filter 'local_*.json' | ForEach-Object { $sourceHashes[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }

    $brokenIndex = Join-Path $sourceDir 'local_broken.json'
    [IO.File]::WriteAllText($brokenIndex, '{not-json')
    $invalid = Invoke-Sessions 'copy-all' @('primary', 'secundary')
    Assert-True ($invalid.ExitCode -ne 0) 'Bulk copy stops on an unreadable source index.'
    Assert-True ($invalid.Output -match 'Cannot read session index') 'Bulk copy reports the unreadable source index.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $targetDir 'local_session-2.json'))) 'Invalid source preflight copies no other entries.'
    Remove-Item -LiteralPath $brokenIndex -Force

    $list = Invoke-Sessions 'list' @('primary')
    Assert-True ($list.ExitCode -eq 0) "Session list exits 0: $($list.Output)"
    Assert-True ($list.Output -match '3 session\(s\)') 'All three fixture sessions parse, including the empty JSON property name.'

    $single = Invoke-Sessions 'copy' @('session-1', 'secundary')
    Assert-True ($single.ExitCode -eq 0) "Single-session copy exits 0: $($single.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $targetDir 'local_session-1.json')) 'Single copy uses the matching source organization folder.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $targetRoot 'org-other') 'local_session-1.json'))) 'Single copy does not use an unrelated organization folder.'

    $conflictPath = Join-Path $targetDir 'local_session-3.json'
    [IO.File]::WriteAllText($conflictPath, '{"different":true}')
    $conflict = Invoke-Sessions 'copy-all' @('primary', 'secundary')
    Assert-True ($conflict.ExitCode -ne 0) 'Bulk copy rejects a differing destination entry.'
    Assert-True ($conflict.Output -match 'no sessions were copied') 'Conflict is reported as a preflight stop.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $targetDir 'local_session-2.json'))) 'Conflict preflight writes none of the other missing entries.'
    Remove-Item -LiteralPath $conflictPath -Force

    $bulk = Invoke-Sessions 'copy-all' @('primary', 'secundary')
    Assert-True ($bulk.ExitCode -eq 0) "Bulk copy exits 0: $($bulk.Output)"
    Assert-True ($bulk.Output -match 'Newly copied\s+: 2') 'Bulk copy adds the two missing entries.'
    Assert-True ($bulk.Output -match 'Already identical\s+: 1') 'Bulk copy skips an identical existing entry.'
    Assert-True ($bulk.Output -match 'Missing transcripts\s+: 2') 'Bulk copy reports entries without local transcripts.'
    foreach ($name in $sourceHashes.Keys) {
        $sourcePath = Join-Path $sourceDir $name
        Assert-True ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -eq $sourceHashes[$name]) "Source index remains unchanged: $name"
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $targetDir $name) -Algorithm SHA256).Hash -eq $sourceHashes[$name]) "Target index matches source: $name"
    }

    $again = Invoke-Sessions 'copy-all' @('primary', 'secundary')
    Assert-True ($again.ExitCode -eq 0) "Repeated bulk copy exits 0: $($again.Output)"
    Assert-True ($again.Output -match 'Newly copied\s+: 0') 'Repeated bulk copy is idempotent.'
    Assert-True ($again.Output -match 'Already identical\s+: 3') 'Repeated bulk copy skips all identical entries.'

    Write-Host 'PASS: PowerShell parsing, empty-key indexes, matching org copy, conflict preflight, byte verification, missing-transcript report, and idempotency.' -ForegroundColor Green
}
finally {
    $env:APPDATA = $oldAppData
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:USERPROFILE = $oldUserProfile

    $testRootFull = [IO.Path]::GetFullPath($testRoot)
    if ($testRootFull.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $testRootFull)) {
        Remove-Item -LiteralPath $testRootFull -Recurse -Force
    }
}
