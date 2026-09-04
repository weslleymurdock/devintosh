#requires -Version 5.1
<#
.SYNOPSIS
    Acquires firmware drivers required by the generated OpenCore configuration.
.DESCRIPTION
    Stages HfsPlus.efi from the official Acidanthera OcBinaryData repository into
    build/efi/EFI/OC/Drivers. The binary is downloaded at build time, verified by
    SHA-256, and is never committed to source control.

    The source commit and expected SHA-256 are pinned for reproducibility.
.PARAMETER Force
    Replace an existing staged driver after verification.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"

$EXIT_CODE=$script:EXIT_SUCCESS
$step=0
$totalSteps=5
$ocRoot=Join-Path $script:BuildRoot 'efi\EFI\OC'
$driverRoot=Join-Path $ocRoot 'Drivers'
$driverPath=Join-Path $driverRoot 'HfsPlus.efi'
$workspace=Join-Path $script:BuildRoot 'opencore-driver-download'
$sourceCommit='e74e533d8f89c1d5014cfb47c185502bf415741f'
$sourceUrl="https://github.com/acidanthera/OcBinaryData/raw/$sourceCommit/Drivers/HfsPlus.efi"
$expectedSha256='5887bd60c36d567be1274873966356b17fddc7742df3c55fb78e1071b5ecbfed'
$maxAttempts=3

function Invoke-HfsPlusDownload {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    $lastError=$null
    for($attempt=1;$attempt -le $maxAttempts;$attempt++){
        Write-DevintoshLog 'INFO' "HfsPlus.efi download attempt $attempt/$maxAttempts from pinned source commit $sourceCommit."
        try {
            if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Force}
            Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $Destination
            if(-not(Test-Path -LiteralPath $Destination -PathType Leaf)){
                throw 'Download did not create the expected file.'
            }

            $item=Get-Item -LiteralPath $Destination -Force
            Write-DevintoshLog 'INFO' "Downloaded HfsPlus.efi size: $($item.Length) bytes."
            if($item.Length -lt 4096){
                throw "Downloaded HfsPlus.efi is unexpectedly small ($($item.Length) bytes)."
            }

            $stream=[System.IO.File]::OpenRead($Destination)
            try {
                $header=New-Object byte[] 2
                $read=$stream.Read($header,0,2)
            }
            finally { $stream.Dispose() }
            if($read -ne 2 -or $header[0] -ne 0x4D -or $header[1] -ne 0x5A){
                throw 'Downloaded HfsPlus.efi does not have a valid PE MZ header.'
            }

            Write-DevintoshLog 'INFO' "HfsPlus.efi PE header validation passed on attempt $attempt/$maxAttempts."
            return
        }
        catch {
            $lastError=$_.Exception
            Write-DevintoshLog 'WARN' "HfsPlus.efi download/PE validation attempt $attempt/$maxAttempts failed: $($lastError.Message)"
            if($attempt -lt $maxAttempts){
                Start-Sleep -Seconds ([Math]::Min(2*$attempt,6))
            }
        }
    }

    throw "Failed to download a valid HfsPlus.efi after $maxAttempts attempts. Last error: $($lastError.Message)"
}

try {
    Initialize-DevintoshLogging -Name 'acquire-opencore-drivers'
    Write-DevintoshLog 'INFO' "Pinned HfsPlus.efi source: $sourceUrl"
    Write-DevintoshLog 'INFO' "Expected HfsPlus.efi SHA-256: $expectedSha256"
    Start-DevintoshTransaction
    $step++;Write-DevintoshProgress $step $totalSteps 'Checking HfsPlus driver prerequisites';if(-not(Test-IsAdministrator)){$EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES;throw 'Administrator privileges are required.'};if(-not(Test-Path -LiteralPath $ocRoot -PathType Container)){$EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND;throw "OpenCore root not found: $ocRoot"};if(-not(Test-Path -LiteralPath $driverRoot -PathType Container)){New-Item -ItemType Directory -Path $driverRoot -Force|Out-Null};if((Test-Path -LiteralPath $driverPath -PathType Leaf) -and -not $Force){$actual=(Get-FileHash -LiteralPath $driverPath -Algorithm SHA256).Hash.ToLowerInvariant();if($actual -eq $expectedSha256){Write-DevintoshStepLog $step 'Existing verified HfsPlus.efi is already staged.' 'PASS';$step=$totalSteps}else{throw 'An unverified HfsPlus.efi is already staged. Re-run with -Force to replace it.'}}else{Write-DevintoshStepLog $step 'HfsPlus driver staging prerequisites are available.' 'PASS'}
    if($step -lt $totalSteps){
        $step++;Write-DevintoshProgress $step $totalSteps 'Downloading pinned HfsPlus.efi';if(Test-Path -LiteralPath $workspace){Remove-Item -LiteralPath $workspace -Recurse -Force};New-Item -ItemType Directory -Path $workspace -Force|Out-Null;$downloadPath=Join-Path $workspace 'HfsPlus.efi';Invoke-HfsPlusDownload -Uri $sourceUrl -Destination $downloadPath;Write-DevintoshStepLog $step 'Pinned HfsPlus.efi downloaded and PE header validated.' 'PASS'
        $step++;Write-DevintoshProgress $step $totalSteps 'Verifying HfsPlus.efi SHA-256';$actual=(Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant();Write-DevintoshLog 'INFO' "HfsPlus.efi SHA-256 expected: $expectedSha256";Write-DevintoshLog 'INFO' "HfsPlus.efi SHA-256 actual:   $actual";if($actual -ne $expectedSha256){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "HfsPlus.efi SHA-256 mismatch. Expected $expectedSha256; got $actual."};Write-DevintoshStepLog $step "HfsPlus.efi SHA-256 verified: $actual." 'PASS'
        $step++;Write-DevintoshProgress $step $totalSteps 'Staging verified HfsPlus.efi';$backupPath=$null;if(Test-Path -LiteralPath $driverPath -PathType Leaf){$backupPath="$driverPath.driver-backup";Copy-Item -LiteralPath $driverPath -Destination $backupPath -Force;Add-DevintoshRollbackAction -Name 'Restore previous HfsPlus.efi' -Action {if(Test-Path -LiteralPath $backupPath){Copy-Item -LiteralPath $backupPath -Destination $driverPath -Force}else{if(Test-Path -LiteralPath $driverPath){Remove-Item -LiteralPath $driverPath -Force}}}}else{Add-DevintoshRollbackAction -Name 'Remove staged HfsPlus.efi' -Action {if(Test-Path -LiteralPath $driverPath){Remove-Item -LiteralPath $driverPath -Force}}};Copy-Item -LiteralPath $downloadPath -Destination $driverPath -Force;Write-DevintoshStepLog $step 'Verified HfsPlus.efi staged under EFI/OC/Drivers.' 'PASS'
        $step++;Write-DevintoshProgress $step $totalSteps 'Writing HfsPlus driver manifest';$manifest=[ordered]@{schemaVersion=1;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);driver='HfsPlus.efi';sourceRepository='acidanthera/OcBinaryData';sourceCommit=$sourceCommit;sourceUrl=$sourceUrl;sha256=$expectedSha256;licenseStatus='Apple binary redistributed by upstream OcBinaryData; fetched at build time, not committed';redistributedByRepository=$false;stagedPath='build/efi/EFI/OC/Drivers/HfsPlus.efi'};$manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $script:BuildRoot 'opencore\hfsplus-driver-manifest.json') -Encoding UTF8;Write-DevintoshStepLog $step 'HfsPlus driver manifest written without embedding the binary.' 'PASS'
    }
    if(Test-Path -LiteralPath $workspace){Remove-Item -LiteralPath $workspace -Recurse -Force};Complete-DevintoshTransaction;Complete-DevintoshProgress 'OpenCore firmware drivers ready';Write-DevintoshLog 'INFO' 'HfsPlus.efi is staged and SHA-256 verified.';exit $script:EXIT_SUCCESS
}catch{Write-DevintoshLog 'ERROR' "OpenCore driver acquisition failed: $($_.Exception.Message)";try{$ok=Invoke-DevintoshRollback;if(-not$ok){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}}catch{$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE};if($EXIT_CODE -eq $script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_GENERAL_FAILURE};exit $EXIT_CODE}
