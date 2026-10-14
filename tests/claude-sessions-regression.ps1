$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Contains {
    param([string]$Text, [string]$Fragment, [string]$Message)
    Assert-True ($Text.Contains($Fragment)) $Message
}

function Write-Utf8File {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Invoke-SessionTool {
    param([string[]]$Arguments)
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $invokeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:SessionTool) + $Arguments
    $output = & $powershell @invokeArgs 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:SessionTool = Join-Path $repoRoot 'claude-sessions.ps1'
$guiPath = Join-Path $repoRoot 'claude-switcher-gui.ps1'
$profilePath = Join-Path $repoRoot 'claude-profile.ps1'
$launcherPath = Join-Path $repoRoot 'claude-switcher-gui.vbs'
$tempRoot = Join-Path $env:TEMP ("claude-switcher-regression-{0}" -f [guid]::NewGuid().ToString('N'))
$tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
if (-not $resolvedTempRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to create test fixtures outside TEMP.'
}

$originalUserProfile = $env:USERPROFILE
$originalAppData = $env:APPDATA
$originalLocalAppData = $env:LOCALAPPDATA

try {
    $env:USERPROFILE = Join-Path $tempRoot 'user'
    $env:APPDATA = Join-Path $tempRoot 'roaming'
    $env:LOCALAPPDATA = Join-Path $tempRoot 'local'

    $appRoot = Join-Path $env:APPDATA 'Claude'
    $sessionsRoot = Join-Path $appRoot 'claude-code-sessions'
    $storeRoot = Join-Path $env:USERPROFILE '.claude-profiles'
    $projectsRoot = Join-Path $env:USERPROFILE '.claude\projects\project-a'
    $sourceRoot = Join-Path $sessionsRoot 'source-uuid'
    $targetRoot = Join-Path $sessionsRoot 'target-uuid'
    $sourceOrgA = Join-Path $sourceRoot 'org-a'
    $sourceOrgB = Join-Path $sourceRoot 'org-b'
    $targetOrgA = Join-Path $targetRoot 'org-a'
    $targetOrgB = Join-Path $targetRoot 'org-b'

    foreach ($path in @($sourceOrgA, $sourceOrgB, $targetOrgA, $targetOrgB, $projectsRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    foreach ($profile in @(@{ Name = 'primary'; Uuid = 'source-uuid' }, @{ Name = 'secondary'; Uuid = 'target-uuid' })) {
        $profileDir = Join-Path $storeRoot $profile.Name
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        $config = @{ lastKnownAccountUuid = $profile.Uuid } | ConvertTo-Json
        Write-Utf8File (Join-Path $profileDir 'config.json') $config
    }

    $sourceIndexes = @{
        (Join-Path $sourceOrgA 'local_parent.json') = '{"sessionId":"parent-1","cliSessionId":"transcript-parent","title":"Parent","cwd":"C:\\\\work","lastActivityAt":1781090000000,"":true}'
        (Join-Path $sourceOrgA 'local_side_same.json') = '{"sessionId":"side-same","cliSessionId":"transcript-missing","title":"Side session with same-org parent","cwd":"C:\\\\work","lastActivityAt":1781090000001,"spawnedFrom":{"sideSession":true,"sessionId":"parent-1"}}'
        (Join-Path $sourceOrgA 'local_side_cross.json') = '{"sessionId":"side-cross","cliSessionId":"transcript-side","title":"Side session with cross-org parent","cwd":"C:\\\\work","lastActivityAt":1781090000002,"spawnedFrom":{"sideSession":true,"sessionId":"cross-parent"}}'
        (Join-Path $sourceOrgB 'local_cross_parent.json') = '{"sessionId":"cross-parent","cliSessionId":"transcript-cross-parent","title":"Cross-org parent","cwd":"C:\\\\work","lastActivityAt":1781090000003}'
    }
    foreach ($entry in $sourceIndexes.GetEnumerator()) { Write-Utf8File $entry.Key $entry.Value }
    Write-Utf8File (Join-Path $projectsRoot 'transcript-parent.jsonl') '{"type":"user"}'
    Write-Utf8File (Join-Path $projectsRoot 'transcript-side.jsonl') '{"type":"user"}'
    Write-Utf8File (Join-Path $projectsRoot 'transcript-cross-parent.jsonl') '{"type":"user"}'

    $sourceHashes = @{}
    foreach ($path in $sourceIndexes.Keys) {
        $sourceHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    Copy-Item -LiteralPath (Join-Path $sourceOrgA 'local_parent.json') -Destination (Join-Path $targetOrgA 'local_parent.json')
    $transcriptCount = @(Get-ChildItem -LiteralPath $projectsRoot -Filter '*.jsonl').Count

    $first = Invoke-SessionTool @('copy-all', 'primary', 'secondary')
    Assert-True ($first.ExitCode -eq 0) 'initial bulk copy succeeds'
    Assert-Contains $first.Output 'Source index entries : 4' 'all source indexes were parsed, including the empty JSON key'
    Assert-Contains $first.Output 'Newly copied         : 3' ("new indexes were copied; actual output:`n{0}" -f $first.Output)
    Assert-Contains $first.Output 'Already identical    : 1' 'identical target indexes are skipped'
    Assert-Contains $first.Output 'Side-session indexes : 2' 'side-session indexes are counted'
    Assert-Contains $first.Output 'Side-session parents : 1/2 resolved' 'side-session parents resolve only within the same organization'
    Assert-Contains $first.Output 'Missing transcripts  : 1' 'missing transcript is reported'

    foreach ($sourcePath in $sourceIndexes.Keys) {
        $targetPath = Join-Path (Join-Path $targetRoot (Split-Path (Split-Path $sourcePath -Parent) -Leaf)) (Split-Path $sourcePath -Leaf)
        Assert-True (Test-Path -LiteralPath $targetPath) "copied index exists: $targetPath"
        $targetHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
        Assert-True ($targetHash -eq $sourceHashes[$sourcePath]) "copied index bytes match source: $targetPath"
        $sourceHashAfter = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        Assert-True ($sourceHashAfter -eq $sourceHashes[$sourcePath]) "source index remains unchanged: $sourcePath"
    }
    $copiedSide = Get-Content -LiteralPath (Join-Path $targetOrgA 'local_side_same.json') -Raw | ConvertFrom-Json
    Assert-True ($copiedSide.spawnedFrom.sideSession -eq $true) 'side-session marker survives the copy'
    Assert-True ($copiedSide.spawnedFrom.sessionId -eq 'parent-1') 'side-session parent id survives the copy'
    Assert-True (@(Get-ChildItem -LiteralPath $projectsRoot -Filter '*.jsonl').Count -eq $transcriptCount) 'transcripts are not copied or modified'

    $second = Invoke-SessionTool @('copy-all', 'primary', 'secondary')
    Assert-True ($second.ExitCode -eq 0) 'repeat bulk copy succeeds'
    Assert-Contains $second.Output 'Newly copied         : 0' 'repeat copy is idempotent'
    Assert-Contains $second.Output 'Already identical    : 4' 'all identical entries are skipped on repeat'

    $missingTarget = Join-Path $targetOrgA 'local_side_same.json'
    Remove-Item -LiteralPath $missingTarget -Force
    Write-Utf8File (Join-Path $targetOrgB 'local_cross_parent.json') '{"different":"target content"}'
    $conflict = Invoke-SessionTool @('copy-all', 'primary', 'secondary')
    Assert-True ($conflict.ExitCode -ne 0) 'different destination content is rejected'
    Assert-Contains $conflict.Output 'different destination index file(s)' 'conflict is reported'
    Assert-True (-not (Test-Path -LiteralPath $missingTarget)) 'conflict preflight copies nothing'

    Copy-Item -LiteralPath (Join-Path $sourceOrgB 'local_cross_parent.json') -Destination (Join-Path $targetOrgB 'local_cross_parent.json') -Force
    Write-Utf8File (Join-Path $sourceOrgA 'local_malformed.json') '{"sessionId":'
    $malformed = Invoke-SessionTool @('copy-all', 'primary', 'secondary')
    Assert-True ($malformed.ExitCode -ne 0) 'malformed source index fails closed'
    Assert-Contains $malformed.Output 'Cannot read session index' 'malformed source index is named'
    Assert-True (-not (Test-Path -LiteralPath $missingTarget)) 'malformed-source preflight copies nothing'

    Remove-Item -LiteralPath (Join-Path $sourceOrgA 'local_malformed.json') -Force
    $recovered = Invoke-SessionTool @('copy-all', 'primary', 'secondary')
    Assert-True ($recovered.ExitCode -eq 0) 'copy succeeds after removing malformed fixture'
    Assert-True ((Get-FileHash -LiteralPath $missingTarget -Algorithm SHA256).Hash -eq $sourceHashes[(Join-Path $sourceOrgA 'local_side_same.json')]) 'recovered copy passes SHA256 readback'

    $guiText = [IO.File]::ReadAllText($guiPath)
    Assert-Contains $guiText 'function Format-ProfileIdentity {' 'GUI has an explicit profile-identity formatter'
    Assert-Contains $guiText 'Claude Code UUID:' 'copy confirmations expose the stable UUID'
    Assert-Contains $guiText 'does not verify the account email' 'copy confirmations explain the email limitation'
    $profileText = [IO.File]::ReadAllText($profilePath)
    Assert-Contains $profileText 'function Get-ClaudeDesktopProcesses {' 'profile commands identify Claude Desktop specifically'
    Assert-Contains $profileText "Get-AppxPackage -Name 'Claude'" 'profile commands use the installed Desktop package path'
    $launcherText = [IO.File]::ReadAllText($launcherPath)
    Assert-Contains $launcherText '-WindowStyle Hidden -File' 'VBS launcher hides the PowerShell console'

    Write-Host 'PASS: session copy parsing, preflight, byte verification, missing transcript, idempotency, side-session links, profile identity, and hidden launcher.' -ForegroundColor Green
} finally {
    $env:USERPROFILE = $originalUserProfile
    $env:APPDATA = $originalAppData
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $resolvedTempRoot) {
        $current = [IO.Path]::GetFullPath($resolvedTempRoot)
        if ($current.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and $current -ne $tempPrefix.TrimEnd('\')) {
            Remove-Item -LiteralPath $current -Recurse -Force
        }
    }
}
