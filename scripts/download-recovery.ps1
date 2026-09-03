#requires -Version 5.1
<#
.SYNOPSIS
    Downloads and verifies the macOS Sequoia Recovery image for Devintosh.

.DESCRIPTION
    Bootstraps the pinned OpenCore macrecovery utility without cloning a repository,
    downloads Apple's macOS Sequoia Recovery payload, relies on macrecovery's signed
    chunklist verification, and records immutable metadata for the generated files.

    The OpenCore utility source is pinned to a known upstream commit. The Recovery
    payload itself is intentionally resolved from Apple's recovery service at runtime,
    because Apple controls the currently available Recovery product for the selected
    board identifier.

.PARAMETER Latest
    Requests the latest Recovery product available for the selected Sequoia board.
    Without this switch the macrecovery default product is requested.

.PARAMETER Force
    Replaces an existing Recovery payload after backing up the current payload.

.EXIT CODES
    0 = Recovery download and verification completed successfully.
    1 = General download or preparation failure.
    2 = Host validation/dependency validation failure.
    3 = Administrator privileges are required.
    4 = Required configuration or resource was not found.
    5 = Automatic rollback failed.
    6 = External dependency or network failure.
    7 = Recovery/tool integrity verification failure.
    8 = Unsupported configuration.
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

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 8
$recoveryRoot = Join-Path $script:BuildRoot 'recovery'
$toolRoot = Join-Path $script:RepoRoot 'tools\macrecovery'
$tempRoot = Join-Path $script:BuildRoot ("recovery-download-" + [Guid]::NewGuid().ToString('N'))
$manifestPath = Join-Path $recoveryRoot 'recovery-manifest.json'

$openCoreCommit = '2a9ce04683ab1d9ca7619bbb4ea4ab869c000ee1'
$openCoreBaseUrl = "https://raw.githubusercontent.com/acidanthera/OpenCorePkg/$openCoreCommit/Utilities/macrecovery"
$macRecoveryUrl = "$openCoreBaseUrl/macrecovery.py"
$macRecoveryBatUrl = "$openCoreBaseUrl/macrecovery.bat"
$configPath = Join-Path $script:RepoRoot 'config\versions\sequoia.json'

Write-DevintoshTitle 'macOS Sequoia Recovery' 'Download from Apple and verify before use.'
Initialize-DevintoshLogging 'download-recovery'
Start-DevintoshTransaction

function Invoke-DownloadTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $tmp = "$Destination.download"
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force
    }

    Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $tmp
    if (-not (Test-Path -LiteralPath $tmp)) {
        throw "Download did not create $tmp"
    }

    Move-Item -LiteralPath $tmp -Destination $Destination -Force
}

function Get-FileMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return [ordered]@{
        name = $item.Name
        sizeBytes = [int64]$item.Length
        sha256 = $hash
    }
}

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking PowerShell and Python dependencies'
    if (-not (Test-IsAdministrator)) {
        Write-DevintoshStepLog $step 'Administrator privileges are required for the recovery workflow.' 'FAIL'
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        throw 'Run download-recovery.ps1 from an elevated PowerShell session.'
    }

    $python = Get-Command py -ErrorAction SilentlyContinue
    $pythonUsesLauncher = $true
    if (-not $python) {
        $python = Get-Command python -ErrorAction SilentlyContinue
        $pythonUsesLauncher = $false
    }
    if (-not $python) {
        Write-DevintoshStepLog $step 'Python 3 was not found in PATH. Install Python 3 and retry.' 'FAIL'
        $EXIT_CODE = $script:EXIT_DEPENDENCY_FAILURE
        throw 'Python 3 is required by OpenCore macrecovery.'
    }
    $pythonCommand = $python.Source
    $versionArgs = if ($pythonUsesLauncher) { @('-3', '--version') } else { @('--version') }
    $versionOutput = & $pythonCommand @versionArgs 2>&1
    if ($LASTEXITCODE -ne 0 -or "$(($versionOutput | Out-String))" -notmatch 'Python 3\.') {
        Write-DevintoshStepLog $step 'The selected Python command is not a usable Python 3 runtime.' 'FAIL'
        $EXIT_CODE = $script:EXIT_DEPENDENCY_FAILURE
        throw 'Python 3 runtime validation failed.'
    }
    Write-DevintoshStepLog $step "Python 3 runtime found: $pythonCommand." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading Sequoia recovery configuration'
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-DevintoshStepLog $step "Missing configuration: $configPath" 'FAIL'
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw 'Sequoia recovery configuration was not found.'
    }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.macOSMajorVersion -ne 15) {
        Write-DevintoshStepLog $step 'The configured recovery profile is not macOS Sequoia.' 'FAIL'
        $EXIT_CODE = $script:EXIT_UNSUPPORTED_CONFIGURATION
        throw 'Only Sequoia is implemented by this phase.'
    }
    $boardId = [string]$config.recovery.boardId
    $mlb = [string]$config.recovery.mlb
    $osType = if ($Latest) { 'latest' } else { [string]$config.recovery.osType }
    Write-DevintoshLog 'INFO' "Recovery board: $boardId; MLB mode: generic; OS mode: $osType; OpenCore commit: $openCoreCommit."
    Write-DevintoshStepLog $step "Sequoia profile loaded for board $boardId." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Preparing pinned macrecovery utility'
    foreach ($directory in @($toolRoot, $recoveryRoot, $tempRoot)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }
    Add-DevintoshRollbackAction "Remove temporary recovery directory $tempRoot" {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }

    $pythonPath = Join-Path $toolRoot 'macrecovery.py'
    $batPath = Join-Path $toolRoot 'macrecovery.bat'
    Invoke-DownloadTextFile -Uri $macRecoveryUrl -Destination $pythonPath
    Invoke-DownloadTextFile -Uri $macRecoveryBatUrl -Destination $batPath
    $toolMetadata = @{
        repository = 'acidanthera/OpenCorePkg'
        path = 'Utilities/macrecovery'
        commit = $openCoreCommit
        source = $openCoreBaseUrl
        macrecoveryPy = Get-FileMetadata $pythonPath
        macrecoveryBat = Get-FileMetadata $batPath
        downloadedAtUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    $toolMetadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $toolRoot 'tool-manifest.json') -Encoding UTF8
    Write-DevintoshStepLog $step "macrecovery pinned to upstream commit $openCoreCommit." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Downloading Apple Recovery payload'

    # Force array semantics here. Under Windows PowerShell 5.1 with strict mode,
    # an empty pipeline result can be AutomationNull and does not safely expose
    # .Count. The direct macrecovery test proved the Apple download path works;
    # this check must therefore distinguish an empty Recovery directory from an
    # actual existing payload without relying on scalar pipeline behavior.
    $existingFiles = @(
        @('BaseSystem.dmg', 'BaseSystem.chunklist') |
            ForEach-Object { Join-Path $recoveryRoot $_ } |
            Where-Object { Test-Path -LiteralPath $_ }
    )

    $backupRoot = $null
    if ($existingFiles.Count -gt 0) {
        if (-not $Force) {
            Write-DevintoshStepLog $step 'A Recovery payload already exists. Use -Force to replace it safely.' 'FAIL'
            $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
            throw 'Existing Recovery payload found.'
        }
        $backupRoot = Join-Path $script:BackupRoot ("recovery-" + (Get-Timestamp))
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        foreach ($existing in $existingFiles) {
            Copy-Item -LiteralPath $existing -Destination $backupRoot -Force
        }
        Add-DevintoshRollbackAction "Restore previous Recovery payload from $backupRoot" {
            if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
                foreach ($backupFile in Get-ChildItem -LiteralPath $backupRoot -File) {
                    Copy-Item -LiteralPath $backupFile.FullName -Destination (Join-Path $recoveryRoot $backupFile.Name) -Force
                }
            }
        }
    }

    # Do not use PowerShell's automatic $args variable here. Keep the native
    # command argument list in an explicitly named variable so the invocation
    # remains deterministic under StrictMode and when this script is called with
    # its own parameters.
    $macRecoveryArguments = @()
    if ($pythonUsesLauncher) { $macRecoveryArguments += '-3' }
    $macRecoveryArguments += @($pythonPath, '-b', $boardId, '-m', $mlb, '-o', $tempRoot)
    if ($Latest) { $macRecoveryArguments += @('-os', 'latest') }
    $macRecoveryArguments += 'download'

    Write-DevintoshLog 'INFO' "Invoking macrecovery for $boardId ($osType)."
    Write-DevintoshLog 'INFO' "macrecovery arguments: $($macRecoveryArguments -join ' ')."

    # Stream macrecovery output to both the terminal and the Devintosh log.
    # This preserves the native process exit code while making Apple/network
    # errors visible to the user instead of hiding them in a captured array.
    $processExitCode = 0
    & $pythonCommand @macRecoveryArguments 2>&1 | ForEach-Object {
        $line = "$($_)"
        if ($line.Trim().Length -gt 0) {
            Write-DevintoshLog 'INFO' $line
            Write-Host "    $line"
        }
    }
    $processExitCode = $LASTEXITCODE

    if ($processExitCode -ne 0) {
        Write-DevintoshStepLog $step "macrecovery failed with exit code $processExitCode." 'FAIL'
        $EXIT_CODE = $script:EXIT_DEPENDENCY_FAILURE
        throw "macrecovery returned exit code $processExitCode."
    }
    Write-DevintoshStepLog $step 'Apple Recovery payload downloaded; macrecovery reported successful chunk verification.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Validating downloaded Recovery files'
    $downloadedDmg = Join-Path $tempRoot 'BaseSystem.dmg'
    $downloadedChunk = Join-Path $tempRoot 'BaseSystem.chunklist'
    if (-not (Test-Path -LiteralPath $downloadedDmg) -or -not (Test-Path -LiteralPath $downloadedChunk)) {
        Write-DevintoshStepLog $step 'Expected BaseSystem.dmg and BaseSystem.chunklist were not produced by macrecovery.' 'FAIL'
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw 'Recovery output files are missing.'
    }

    $dmgMeta = Get-FileMetadata $downloadedDmg
    $chunkMeta = Get-FileMetadata $downloadedChunk
    if ($dmgMeta.sizeBytes -le 0 -or $chunkMeta.sizeBytes -le 0) {
        Write-DevintoshStepLog $step 'Recovery files are empty.' 'FAIL'
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw 'Recovery files are empty.'
    }
    Write-DevintoshLog 'INFO' "BaseSystem.dmg SHA256: $($dmgMeta.sha256); size: $($dmgMeta.sizeBytes) bytes."
    Write-DevintoshLog 'INFO' "BaseSystem.chunklist SHA256: $($chunkMeta.sha256); size: $($chunkMeta.sizeBytes) bytes."
    Write-DevintoshStepLog $step 'Recovery files passed local integrity checks.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Installing verified Recovery payload into build workspace'
    foreach ($file in Get-ChildItem -LiteralPath $recoveryRoot -File -ErrorAction SilentlyContinue) {
        if ($file.Name -ne 'recovery-manifest.json') {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
    Copy-Item -LiteralPath $downloadedDmg -Destination $recoveryRoot -Force
    Copy-Item -LiteralPath $downloadedChunk -Destination $recoveryRoot -Force
    $installedDmg = Join-Path $recoveryRoot 'BaseSystem.dmg'
    $installedChunk = Join-Path $recoveryRoot 'BaseSystem.chunklist'
    if (-not (Test-Path -LiteralPath $installedDmg) -or -not (Test-Path -LiteralPath $installedChunk)) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw 'Verified Recovery files could not be installed into the build workspace.'
    }
    Write-DevintoshStepLog $step 'Verified Recovery payload installed in build/recovery.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing Recovery manifest'
    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        culture = 'en-US'
        macOSFamily = 'Sequoia'
        macOSMajorVersion = 15
        boardId = $boardId
        mlbMode = 'generic'
        osType = $osType
        source = 'Apple Internet Recovery via OpenCore macrecovery'
        opencoreRepository = 'acidanthera/OpenCorePkg'
        opencoreCommit = $openCoreCommit
        verification = 'macrecovery chunklist verification plus local SHA-256 metadata'
        files = @(
            [ordered]@{ name = 'BaseSystem.dmg'; sizeBytes = $dmgMeta.sizeBytes; sha256 = $dmgMeta.sha256 },
            [ordered]@{ name = 'BaseSystem.chunklist'; sizeBytes = $chunkMeta.sizeBytes; sha256 = $chunkMeta.sha256 }
        )
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-DevintoshStepLog $step "Recovery manifest written to $manifestPath." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing recovery transaction'
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    Complete-DevintoshTransaction
    Write-DevintoshStepLog $step 'Recovery is ready for the installer build phase.' 'PASS'
    Complete-DevintoshProgress 'Recovery ready'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
    Write-DevintoshStepLog $step 'Recovery phase failed; starting automatic rollback.' 'FAIL'
    $rollbackOk = Invoke-DevintoshRollback
    if (-not $rollbackOk) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    Write-DevintoshProgress $step $totalSteps 'Recovery phase failed'
    Write-Host ''
    Write-Host "[$($script:Red)FAIL$($script:Reset)] download-recovery.ps1 exited with code $EXIT_CODE"
    exit $EXIT_CODE
}
