#requires -Version 5.1
<#
.SYNOPSIS
    Downloads, verifies, caches, and restores the selected macOS Recovery payload.
.DESCRIPTION
    Keeps the Recovery cache outside the repository at the root of the drive that
    contains the clone. The cache is exposed through DEVINTOSH_RECOVERY_CACHE.

    Cached Recovery is accepted only when its metadata matches the selected version
    profile, the pinned BaseSystem.chunklist SHA-256 matches, both files are present,
    and the pinned macrecovery verifier confirms every DMG chunk locally.

    A valid cache therefore avoids all Apple Recovery network requests. An invalid
    or missing cache is replaced only after a fresh macrecovery download completes
    and passes the same integrity checks.
#>
[CmdletBinding()]
param(
    [switch]$Latest,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"
. "$PSScriptRoot\lib\version-profile.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 8
$recoveryRoot = Join-Path $script:BuildRoot 'recovery'
$toolRoot = Join-Path $script:RepoRoot 'tools\macrecovery'
$tempRoot = Join-Path $script:BuildRoot ("recovery-download-" + [Guid]::NewGuid().ToString('N'))
$manifestPath = Join-Path $recoveryRoot 'recovery-manifest.json'
$versionProfile = Get-DevintoshVersionProfile
$recoveryProfile = $versionProfile.recovery
$boardId = [string]$recoveryProfile.boardId
$mlb = [string]$recoveryProfile.mlb
$osType = [string]$recoveryProfile.osType
$expectedChunkSha = ([string]$recoveryProfile.chunklistSha256).ToLowerInvariant()
$cacheRoot = Join-Path ([System.IO.Path]::GetPathRoot($script:RepoRoot)) 'DevintoshRecoveryCache'
$env:DEVINTOSH_RECOVERY_CACHE = $cacheRoot
$cacheKey = "{0}-{1}-{2}" -f [string]$versionProfile.id, $boardId, $osType
$cachePath = Join-Path $cacheRoot $cacheKey
$cacheManifestPath = Join-Path $cachePath 'recovery-manifest.json'

function Get-FileMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    return [ordered]@{
        name = $item.Name
        sizeBytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Invoke-DownloadTextFile {
    param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][string]$Destination)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $tmp = "$Destination.download"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $tmp
    if (-not (Test-Path -LiteralPath $tmp)) { throw "Download did not create $tmp" }
    Move-Item -LiteralPath $tmp -Destination $Destination -Force
}

function Invoke-MacRecoveryChunkValidation {
    param(
        [Parameter(Mandatory)][string]$PythonCommand,
        [Parameter(Mandatory)][bool]$UsesLauncher,
        [Parameter(Mandatory)][string]$VerifierPath,
        [Parameter(Mandatory)][string]$DmgPath,
        [Parameter(Mandatory)][string]$ChunkPath
    )

    $pythonCode = 'import sys; sys.path.insert(0, r"' + (Split-Path -Parent $VerifierPath).Replace('\','\\') + '"); import macrecovery; macrecovery.verify_image(r"' + $DmgPath.Replace('\','\\') + '", r"' + $ChunkPath.Replace('\','\\') + '")'
    $arguments = @()
    if ($UsesLauncher) { $arguments += '-3' }
    $arguments += @('-c', $pythonCode)
    & $PythonCommand @arguments 2>&1 | ForEach-Object {
        if ("$_".Trim().Length -gt 0) { Write-DevintoshLog 'INFO' "chunk-verify: $_" }
    }
    $code = [int]$LASTEXITCODE
    if ($code -ne 0) { throw "macrecovery chunk verification failed with exit code $code." }
}

function Test-RecoverySet {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$VerifierPath,[Parameter(Mandatory)][string]$PythonCommand,[Parameter(Mandatory)][bool]$UsesLauncher)
    $dmg = Join-Path $Root 'BaseSystem.dmg'
    $chunk = Join-Path $Root 'BaseSystem.chunklist'
    if (-not (Test-Path -LiteralPath $dmg -PathType Leaf) -or -not (Test-Path -LiteralPath $chunk -PathType Leaf)) { return $false }
    $chunkMeta = Get-FileMetadata $chunk
    if ($chunkMeta.sha256 -ne $expectedChunkSha) { return $false }
    try {
        Invoke-MacRecoveryChunkValidation -PythonCommand $PythonCommand -UsesLauncher $UsesLauncher -VerifierPath $VerifierPath -DmgPath $dmg -ChunkPath $chunk
        return $true
    } catch {
        Write-DevintoshLog 'WARN' "Cached Recovery chunk verification failed: $($_.Exception.Message)"
        return $false
    }
}

function Write-RecoveryManifest {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $dmgMeta = Get-FileMetadata (Join-Path $Root 'BaseSystem.dmg')
    $chunkMeta = Get-FileMetadata (Join-Path $Root 'BaseSystem.chunklist')
    $manifest = [ordered]@{
        schemaVersion = 2
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        culture = 'en-US'
        targetId = [string]$versionProfile.id
        macOSFamily = [string]$versionProfile.macOSFamily
        macOSMajorVersion = [int]$versionProfile.macOSMajorVersion
        boardId = $boardId
        mlbMode = 'generic'
        osType = $osType
        source = 'Apple Internet Recovery via OpenCore macrecovery'
        opencoreRepository = [string]$versionProfile.opencore.repository
        opencoreVersion = [string]$versionProfile.opencore.version
        opencoreCommit = [string]$versionProfile.opencore.pinnedCommit
        pinnedChunklistSha256 = $expectedChunkSha
        verification = 'macrecovery signed chunklist verification plus pinned chunklist SHA-256'
        files = @(
            [ordered]@{ name='BaseSystem.dmg'; sizeBytes=$dmgMeta.sizeBytes; sha256=$dmgMeta.sha256 },
            [ordered]@{ name='BaseSystem.chunklist'; sizeBytes=$chunkMeta.sizeBytes; sha256=$chunkMeta.sha256 }
        )
    }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Install-RecoveryToBuild {
    param([Parameter(Mandatory)][string]$SourceRoot)
    if (-not (Test-Path -LiteralPath $recoveryRoot)) { New-Item -ItemType Directory -Path $recoveryRoot -Force | Out-Null }
    foreach ($name in @('BaseSystem.dmg','BaseSystem.chunklist')) {
        $destination = Join-Path $recoveryRoot $name
        $partial = "$destination.tmp"
        Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination $partial -Force
        Move-Item -LiteralPath $partial -Destination $destination -Force
    }
}

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking PowerShell and Python dependencies'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Run download-recovery.ps1 from an elevated PowerShell session.' }
    $python = Get-Command py -ErrorAction SilentlyContinue
    $pythonUsesLauncher = $true
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue; $pythonUsesLauncher = $false }
    if (-not $python) { $EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE; throw 'Python 3 is required by OpenCore macrecovery.' }
    $pythonCommand = $python.Source
    $versionArgs = if ($pythonUsesLauncher) { @('-3','--version') } else { @('--version') }
    $versionOutput = & $pythonCommand @versionArgs 2>&1
    if ($LASTEXITCODE -ne 0 -or "$(($versionOutput | Out-String))" -notmatch 'Python 3\.') { $EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE; throw 'Python 3 runtime validation failed.' }
    Write-DevintoshStepLog $step "Python 3 runtime found: $pythonCommand." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading the selected macOS Recovery profile'
    if ([string]::IsNullOrWhiteSpace($boardId) -or [string]::IsNullOrWhiteSpace($osType) -or $expectedChunkSha -notmatch '^[0-9a-f]{64}$') { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'Recovery profile is incomplete or has an invalid chunklist SHA-256.' }
    Write-DevintoshStepLog $step "$($versionProfile.macOSFamily) Recovery selected for board $boardId; pinned chunklist SHA-256: $expectedChunkSha." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Preparing the persistent Recovery cache'
    foreach ($directory in @($recoveryRoot,$cacheRoot,$cachePath,$toolRoot,$tempRoot)) { if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null } }
    Write-DevintoshLog 'INFO' "DEVINTOSH_RECOVERY_CACHE=$env:DEVINTOSH_RECOVERY_CACHE"
    Write-DevintoshLog 'INFO' "Recovery cache key=$cacheKey"
    Add-DevintoshRollbackAction "Remove temporary recovery directory $tempRoot" { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }

    $pythonPath = Join-Path $toolRoot 'macrecovery.py'
    $batPath = Join-Path $toolRoot 'macrecovery.bat'
    $openCoreCommit = [string]$versionProfile.opencore.pinnedCommit
    $macRecoveryBaseUrl = "https://raw.githubusercontent.com/{0}/{1}/{2}" -f [string]$versionProfile.opencore.repository,$openCoreCommit,[string]$versionProfile.opencore.toolPath
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) { Invoke-DownloadTextFile -Uri "$macRecoveryBaseUrl/macrecovery.py" -Destination $pythonPath }
    if (-not (Test-Path -LiteralPath $batPath -PathType Leaf)) { Invoke-DownloadTextFile -Uri "$macRecoveryBaseUrl/macrecovery.bat" -Destination $batPath }
    Write-DevintoshStepLog $step 'Pinned macrecovery utility is available locally.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking cached Recovery integrity'
    if (Test-Path -LiteralPath $cacheManifestPath -PathType Leaf) {
        try {
            $cachedManifest = Get-Content -LiteralPath $cacheManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $metadataMatches = ([string]$cachedManifest.targetId -eq [string]$versionProfile.id) -and ([string]$cachedManifest.boardId -eq $boardId) -and ([string]$cachedManifest.osType -eq $osType) -and ([string]$cachedManifest.pinnedChunklistSha256).ToLowerInvariant() -eq $expectedChunkSha
            if ($metadataMatches -and (Test-RecoverySet -Root $cachePath -VerifierPath $pythonPath -PythonCommand $pythonCommand -UsesLauncher $pythonUsesLauncher)) {
                Install-RecoveryToBuild -SourceRoot $cachePath
                Copy-Item -LiteralPath $cacheManifestPath -Destination $manifestPath -Force
                Write-DevintoshLog 'INFO' 'Persistent Recovery cache passed metadata, SHA-256, and local chunk verification.'
                Write-DevintoshStepLog $step 'Valid Recovery cache found; Apple download was skipped.' 'PASS'
                $step++
                Write-DevintoshProgress $step $totalSteps 'Restoring verified Recovery into the build workspace'
                Write-DevintoshStepLog $step 'Recovery restored from persistent cache.' 'PASS'
                $step++
                Write-DevintoshProgress $step $totalSteps 'Finalizing cached Recovery transaction'
                Complete-DevintoshTransaction
                Write-DevintoshStepLog $step 'Recovery cache restore completed without network access.' 'PASS'
                Complete-DevintoshProgress 'Recovery cache restore complete'
                exit $script:EXIT_SUCCESS
            }
        } catch { Write-DevintoshLog 'WARN' "Recovery cache is invalid and will be replaced: $($_.Exception.Message)" }
    }
    Write-DevintoshStepLog $step 'No valid persistent Recovery cache is available; a fresh Apple download is required.' 'WARN'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Downloading and verifying Apple Recovery'
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $arguments = @()
    if ($pythonUsesLauncher) { $arguments += '-3' }
    $arguments += @($pythonPath,'-b',$boardId,'-m',$mlb,'-o',$tempRoot)
    if ($Latest) { $arguments += @('-os','latest') }
    $arguments += 'download'
    & $pythonCommand @arguments 2>&1 | ForEach-Object { $line="$_"; if($line.Trim().Length -gt 0){Write-DevintoshLog 'INFO' $line;Write-Host "    $line"} }
    if ($LASTEXITCODE -ne 0) { $EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE; throw "macrecovery returned exit code $LASTEXITCODE." }
    $dmgPath=Join-Path $tempRoot 'BaseSystem.dmg';$chunkPath=Join-Path $tempRoot 'BaseSystem.chunklist'
    if(-not(Test-Path -LiteralPath $dmgPath -PathType Leaf)-or-not(Test-Path -LiteralPath $chunkPath -PathType Leaf)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'macrecovery did not produce the expected Recovery files.'}
    $chunkMeta=Get-FileMetadata $chunkPath
    if($chunkMeta.sha256-ne$expectedChunkSha){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "Recovery chunklist SHA-256 mismatch. Expected $expectedChunkSha; received $($chunkMeta.sha256)."}
    Invoke-MacRecoveryChunkValidation -PythonCommand $pythonCommand -UsesLauncher $pythonUsesLauncher -VerifierPath $pythonPath -DmgPath $dmgPath -ChunkPath $chunkPath
    Write-DevintoshStepLog $step "Apple Recovery downloaded and chunk-verified. Pinned chunklist SHA-256: $expectedChunkSha." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Committing verified Recovery to the persistent cache'
    $cacheStage = "$cachePath.staging"
    if(Test-Path -LiteralPath $cacheStage){Remove-Item -LiteralPath $cacheStage -Recurse -Force}
    New-Item -ItemType Directory -Path $cacheStage -Force | Out-Null
    Copy-Item -LiteralPath $dmgPath -Destination $cacheStage -Force
    Copy-Item -LiteralPath $chunkPath -Destination $cacheStage -Force
    Write-RecoveryManifest -Root $cacheStage -Path (Join-Path $cacheStage 'recovery-manifest.json')
    if(Test-Path -LiteralPath $cachePath){Remove-Item -LiteralPath $cachePath -Recurse -Force}
    Move-Item -LiteralPath $cacheStage -Destination $cachePath -Force
    Write-DevintoshStepLog $step "Verified Recovery cached at $cachePath." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Installing verified Recovery into the build workspace'
    Install-RecoveryToBuild -SourceRoot $cachePath
    Copy-Item -LiteralPath (Join-Path $cachePath 'recovery-manifest.json') -Destination $manifestPath -Force
    if(-not(Test-RecoverySet -Root $recoveryRoot -VerifierPath $pythonPath -PythonCommand $pythonCommand -UsesLauncher $pythonUsesLauncher)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'Installed Recovery failed final local validation.'}
    Write-DevintoshStepLog $step 'Verified Recovery installed in build/recovery.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing Recovery transaction'
    if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}
    Complete-DevintoshTransaction
    Write-DevintoshStepLog $step 'Recovery is ready for the installer build phase.' 'PASS'
    Complete-DevintoshProgress 'Recovery preparation complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    if($EXIT_CODE -eq $script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_GENERAL_FAILURE}
    try{ $ok=Invoke-DevintoshRollback;if(-not$ok){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE} }catch{$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}
    Write-DevintoshProgress $step $totalSteps 'Recovery preparation failed'
    exit $EXIT_CODE
}
