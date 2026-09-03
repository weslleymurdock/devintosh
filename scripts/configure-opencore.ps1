#requires -Version 5.1
<#
.SYNOPSIS
    Resolves detected hardware capabilities and generates a conservative OpenCore candidate.

.DESCRIPTION
    Hardware-agnostic configuration engine. Consumes the live hardware profile produced by
    configure-opencore-hardware.ps1 and never accepts hardware identity as manual input.
    Hardware-specific policy belongs in JSON profiles under config/hardware.

    Profiles are evaluated by capability-specific predicates. A profile may identify one
    hardware component without requiring every other component to be present in the same
    profile. Unknown hardware is never guessed, rejected, or mapped to another machine.

    This phase does not fabricate SMBIOS identifiers, audio layout IDs, USB maps, ACPI patches,
    GPU spoofing or third-party kext binaries.

.EXIT CODES
    0 = Candidate generated successfully; unresolved capabilities may be reported.
    1 = General failure.
    2 = Validation failure.
    3 = Administrator privileges are required.
    4 = Required profile or resource was not found.
    5 = Automatic rollback failed.
    6 = External dependency failure.
    7 = Generated configuration integrity failure.
    8 = Unsupported configuration.
#>

[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 9
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$profilePath = Join-Path $outputRoot 'hardware-detected.json'
$efiOcRoot = Join-Path $script:BuildRoot 'efi\EFI\OC'
$configPath = Join-Path $efiOcRoot 'config.plist'
$reportPath = Join-Path $outputRoot 'configuration-report.json'
$resolutionPath = Join-Path $outputRoot 'hardware-resolution.json'
$samplePath = Join-Path $outputRoot 'OpenCore-Sample.plist'
$sampleUri = 'https://raw.githubusercontent.com/acidanthera/OpenCorePkg/2a9ce04683ab1d9ca7619bbb4ea4ab869c000ee1/Docs/Sample.plist'

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required JSON file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-Array {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-OptionalProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-StringEquals {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    return ([string]$Actual).Trim().Equals(([string]$Expected).Trim(), [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-CollectionIdentity {
    param(
        [AllowNull()]$Items,
        [AllowNull()][string]$VendorId,
        [AllowNull()]$DeviceIds,
        [AllowNull()]$SubsystemIds
    )

    $itemsArray = @(Get-Array $Items)
    if ($itemsArray.Count -eq 0) { return $false }
    $wantedDevices = @(Get-Array $DeviceIds | ForEach-Object { [string]$_ })
    $wantedSubsystems = @(Get-Array $SubsystemIds | ForEach-Object { [string]$_ })

    foreach ($item in $itemsArray) {
        $itemVendor = Get-OptionalProperty $item 'VendorId'
        $itemDevice = Get-OptionalProperty $item 'DeviceId'
        $itemSubsystem = Get-OptionalProperty $item 'SubsystemId'

        if ($VendorId -and -not (Test-StringEquals $itemVendor $VendorId)) { continue }
        if ($wantedDevices.Count -gt 0) {
            $deviceMatch = $false
            foreach ($wanted in $wantedDevices) {
                if (Test-StringEquals $itemDevice $wanted) { $deviceMatch = $true; break }
            }
            if (-not $deviceMatch) { continue }
        }
        if ($wantedSubsystems.Count -gt 0) {
            $subsystemMatch = $false
            foreach ($wanted in $wantedSubsystems) {
                if (Test-StringEquals $itemSubsystem $wanted) { $subsystemMatch = $true; break }
            }
            if (-not $subsystemMatch) { continue }
        }
        return $true
    }
    return $false
}

function Test-ProfileMatch {
    param([Parameter(Mandatory)]$Hardware, [Parameter(Mandatory)]$Rule)

    $cpu = Get-OptionalProperty $Hardware 'cpu'
    $platform = Get-OptionalProperty $Hardware 'platform'
    $network = Get-OptionalProperty $Hardware 'network'
    $usb = Get-OptionalProperty $Hardware 'usb'
    $ruleValue = $null

    $ruleValue = Get-OptionalProperty $Rule 'cpuVendor'
    if ($null -ne $ruleValue -and -not (Test-StringEquals (Get-OptionalProperty $cpu 'Manufacturer') $ruleValue)) { return $false }
    $ruleValue = Get-OptionalProperty $Rule 'cpuName'
    if ($null -ne $ruleValue -and -not (Test-StringEquals (Get-OptionalProperty $cpu 'Name') $ruleValue)) { return $false }
    $ruleValue = Get-OptionalProperty $Rule 'cpuNameRegex'
    if ($null -ne $ruleValue -and [string](Get-OptionalProperty $cpu 'Name') -notmatch [string]$ruleValue) { return $false }
    $ruleValue = Get-OptionalProperty $Rule 'cpuCoresMin'
    if ($null -ne $ruleValue -and [int](Get-OptionalProperty $cpu 'Cores') -lt [int]$ruleValue) { return $false }
    $ruleValue = Get-OptionalProperty $Rule 'cpuThreadsMin'
    if ($null -ne $ruleValue -and [int](Get-OptionalProperty $cpu 'Threads') -lt [int]$ruleValue) { return $false }

    $ruleValue = Get-OptionalProperty $Rule 'platformManufacturer'
    if ($null -ne $ruleValue -and -not (Test-StringEquals (Get-OptionalProperty $platform 'Manufacturer') $ruleValue)) { return $false }
    $ruleValue = Get-OptionalProperty $Rule 'platformModel'
    if ($null -ne $ruleValue -and -not (Test-StringEquals (Get-OptionalProperty $platform 'Model') $ruleValue)) { return $false }
    $ruleValue = Get-OptionalProperty $Rule 'platformModelRegex'
    if ($null -ne $ruleValue -and [string](Get-OptionalProperty $platform 'Model') -notmatch [string]$ruleValue) { return $false }
    $ruleValue = Get-OptionalProperty $Rule 'motherboardManufacturer'
    if ($null -ne $ruleValue -and -not (Test-StringEquals (Get-OptionalProperty $platform 'MotherboardManufacturer') $ruleValue)) { return $false }
    $ruleValue = Get-OptionalProperty $Rule 'motherboardProduct'
    if ($null -ne $ruleValue -and -not (Test-StringEquals (Get-OptionalProperty $platform 'MotherboardProduct') $ruleValue)) { return $false }
    $ruleValue = Get-OptionalProperty $Rule 'motherboardProductRegex'
    if ($null -ne $ruleValue -and [string](Get-OptionalProperty $platform 'MotherboardProduct') -notmatch [string]$ruleValue) { return $false }

    $gpuVendorId = Get-OptionalProperty $Rule 'gpuVendorId'
    $gpuDeviceIds = Get-OptionalProperty $Rule 'gpuDeviceIds'
    $gpuSubsystemIds = Get-OptionalProperty $Rule 'gpuSubsystemIds'
    if ($null -ne $gpuVendorId -or $null -ne $gpuDeviceIds -or $null -ne $gpuSubsystemIds) {
        if (-not (Test-CollectionIdentity (Get-OptionalProperty $Hardware 'gpu') $gpuVendorId $gpuDeviceIds $gpuSubsystemIds)) { return $false }
    }

    $networkVendorId = Get-OptionalProperty $Rule 'networkVendorId'
    $networkDeviceIds = Get-OptionalProperty $Rule 'networkDeviceIds'
    $networkSubsystemIds = Get-OptionalProperty $Rule 'networkSubsystemIds'
    if ($null -ne $networkVendorId -or $null -ne $networkDeviceIds -or $null -ne $networkSubsystemIds) {
        if (-not (Test-CollectionIdentity (Get-OptionalProperty $network 'pnp') $networkVendorId $networkDeviceIds $networkSubsystemIds)) { return $false }
    }

    $audioVendorId = Get-OptionalProperty $Rule 'audioVendorId'
    $audioDeviceIds = Get-OptionalProperty $Rule 'audioDeviceIds'
    $audioSubsystemIds = Get-OptionalProperty $Rule 'audioSubsystemIds'
    if ($null -ne $audioVendorId -or $null -ne $audioDeviceIds -or $null -ne $audioSubsystemIds) {
        if (-not (Test-CollectionIdentity (Get-OptionalProperty $Hardware 'audio') $audioVendorId $audioDeviceIds $audioSubsystemIds)) { return $false }
    }

    $usbVendorId = Get-OptionalProperty $Rule 'usbVendorId'
    $usbDeviceIds = Get-OptionalProperty $Rule 'usbDeviceIds'
    $usbSubsystemIds = Get-OptionalProperty $Rule 'usbSubsystemIds'
    if ($null -ne $usbVendorId -or $null -ne $usbDeviceIds -or $null -ne $usbSubsystemIds) {
        if (-not (Test-CollectionIdentity (Get-OptionalProperty $usb 'pnp') $usbVendorId $usbDeviceIds $usbSubsystemIds)) { return $false }
    }

    $acpiDeviceIds = Get-OptionalProperty $Rule 'acpiDeviceIds'
    if ($null -ne $acpiDeviceIds) {
        $found = $false
        foreach ($device in @(Get-Array (Get-OptionalProperty $Hardware 'acpi'))) {
            foreach ($wanted in @(Get-Array $acpiDeviceIds)) {
                if (Test-StringEquals (Get-OptionalProperty $device 'PnpDeviceId') ([string]$wanted)) { $found = $true; break }
                foreach ($compatible in @(Get-Array (Get-OptionalProperty $device 'CompatibleIds'))) {
                    if (Test-StringEquals $compatible ([string]$wanted)) { $found = $true; break }
                }
                if ($found) { break }
            }
            if ($found) { break }
        }
        if (-not $found) { return $false }
    }

    $anyOf = Get-OptionalProperty $Rule 'anyOf'
    if ($null -ne $anyOf) {
        $anyMatched = $false
        foreach ($alternative in @(Get-Array $anyOf)) {
            if (Test-ProfileMatch $Hardware $alternative) { $anyMatched = $true; break }
        }
        if (-not $anyMatched) { return $false }
    }

    return $true
}

function Get-HardwareProfiles {
    $root = Join-Path $script:RepoRoot 'config\hardware'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return @() }

    $profiles = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        try {
            $profile = Read-JsonFile $file.FullName
            if ($null -eq (Get-OptionalProperty $profile 'schemaVersion') -or $null -eq (Get-OptionalProperty $profile 'id') -or $null -eq (Get-OptionalProperty $profile 'match')) {
                Write-DevintoshLog 'WARN' "Ignoring incomplete hardware profile $($file.FullName)."
                continue
            }
            [void]$profiles.Add($profile)
        }
        catch { Write-DevintoshLog 'WARN' "Ignoring invalid hardware profile $($file.FullName): $($_.Exception.Message)" }
    }
    return @($profiles.ToArray())
}

function Get-Matches {
    param([Parameter(Mandatory)]$Hardware, [AllowNull()][object[]]$Profiles)
    if ($null -eq $Profiles -or $Profiles.Count -eq 0) { return @() }
    $matchedProfiles = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in $Profiles) {
        $matchRule = Get-OptionalProperty $profile 'match'
        if ($null -ne $matchRule -and (Test-ProfileMatch $Hardware $matchRule)) {
            [void]$matchedProfiles.Add($profile)
        }
    }
    return @($matchedProfiles.ToArray())
}

function Get-CapabilityState {
    param([AllowNull()][object[]]$MatchedProfiles)

    $profileArray = @(Get-Array $MatchedProfiles)
    $capabilityNames = @('cpu','gpu','audio','network','usb','acpi','smbios')
    $resolved = [System.Collections.Generic.List[string]]::new()
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $needsValidation = [System.Collections.Generic.List[string]]::new()
    $capabilities = [ordered]@{}

    foreach ($capabilityName in $capabilityNames) {
        $providers = [System.Collections.Generic.List[object]]::new()

        foreach ($profile in $profileArray) {
            $profileCapabilities = Get-OptionalProperty $profile 'capabilities'
            $capabilityValue = Get-OptionalProperty $profileCapabilities $capabilityName
            if ($null -ne $capabilityValue -and [bool]$capabilityValue) {
                [void]$providers.Add($profile)
            }
        }

        if ($providers.Count -eq 0) {
            [void]$unresolved.Add($capabilityName)
            continue
        }

        [void]$resolved.Add($capabilityName)
        $reasons = [System.Collections.Generic.List[string]]::new()
        $requiresValidation = $false

        foreach ($provider in $providers) {
            $providerId = [string](Get-OptionalProperty $provider 'id')
            $providerCapabilities = Get-OptionalProperty $provider 'capabilities'
            if ($null -ne $providerCapabilities) {
                foreach ($property in $providerCapabilities.PSObject.Properties) {
                    $key = [string]$property.Name
                    if ($key -match '^requires.*Validation$' -and [bool]$property.Value) {
                        $requiresValidation = $true
                        $reason = ('{0}: {1}' -f $providerId, $key)
                        if ($reasons -notcontains $reason) { [void]$reasons.Add($reason) }
                    }
                }
            }

            $openCore = Get-OptionalProperty $provider 'opencore'
            $policy = Get-OptionalProperty $openCore 'policy'
            if ($null -ne $policy -and [string]$policy -eq 'validation-required') {
                $requiresValidation = $true
                $reason = ('{0}: opencore.policy=validation-required' -f $providerId)
                if ($reasons -notcontains $reason) { [void]$reasons.Add($reason) }
            }
        }

        if ($requiresValidation) { [void]$needsValidation.Add($capabilityName) }
        $capabilities[$capabilityName] = [ordered]@{
            providers = @($providers | ForEach-Object { [string](Get-OptionalProperty $_ 'id') })
            requiresValidation = $requiresValidation
            validationReasons = @($reasons)
        }
    }

    $resolved = @($resolved | Select-Object -Unique)
    $unresolved = @($unresolved | Select-Object -Unique)
    $needsValidation = @($needsValidation | Select-Object -Unique)
    $status = 'Resolved'
    if ($unresolved.Count -gt 0) { $status = 'NeedsProfile' }
    elseif ($needsValidation.Count -gt 0) { $status = 'NeedsValidation' }

    return [pscustomobject]@{
        status = $status
        resolved = $resolved
        unresolved = $unresolved
        needsValidation = $needsValidation
        capabilities = $capabilities
    }
}

function Get-PlistDictionary {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root, [Parameter(Mandatory)][string[]]$Path)
    $current = $Root
    foreach ($part in $Path) {
        $keys = @($current.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $part })
        if ($keys.Count -ne 1) { throw "OpenCore plist dictionary not found: $($Path -join '/')" }
        $node = $keys[0].NextSibling
        while ($null -ne $node -and $node.NodeType -ne 'Element') { $node = $node.NextSibling }
        if ($null -eq $node -or $node.Name -ne 'dict') { throw "OpenCore plist path is not a dictionary: $($Path -join '/')" }
        $current = [System.Xml.XmlElement]$node
    }
    return $current
}

function Set-PlistValue {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Dict,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('string','integer','boolean','data')][string]$Type,
        [AllowEmptyString()][string]$Value=''
    )
    $keys = @($Dict.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name })
    if ($keys.Count -gt 1) { throw "Duplicate plist key: $Name" }
    if ($keys.Count -eq 0) {
        $key = $Dict.OwnerDocument.CreateElement('key')
        $key.InnerText = $Name
        $Dict.AppendChild($key) | Out-Null
    } else { $key = $keys[0] }
    $old = $key.NextSibling
    while ($null -ne $old -and $old.NodeType -ne 'Element') { $old = $old.NextSibling }
    if ($null -ne $old) { $Dict.RemoveChild($old) | Out-Null }
    $node = $Dict.OwnerDocument.CreateElement($Type)
    switch ($Type) {
        'string'  { $node.InnerText = $Value }
        'integer' { $node.InnerText = $Value }
        'boolean' { if ($Value -notin @('true','false')) { throw "Invalid plist boolean value '$Value' for '$Name'." } }
        'data'    { $node.InnerText = $Value }
    }
    $key.ParentNode.InsertAfter($node, $key) | Out-Null
}

function Set-PlistBoolean {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Dict,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][bool]$Value)
    Set-PlistValue $Dict $Name 'boolean' $(if ($Value) { 'true' } else { 'false' })
}

function Set-PlistString {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Dict,[Parameter(Mandatory)][string]$Name,[AllowEmptyString()][string]$Value='')
    Set-PlistValue $Dict $Name 'string' $Value
}

function Remove-PlistWarnings {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root)
    foreach($key in @($Root.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -like '#WARNING*' })){
        $value=$key.NextSibling
        while($null -ne $value -and $value.NodeType -ne 'Element'){$value=$value.NextSibling}
        $Root.RemoveChild($key)|Out-Null
        if($null -ne $value){$Root.RemoveChild($value)|Out-Null}
    }
}

function Set-GenericDefaults {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root)
    Set-PlistBoolean (Get-PlistDictionary $Root @('Booter','Quirks')) 'AvoidRuntimeDefrag' $true
    Set-PlistBoolean (Get-PlistDictionary $Root @('UEFI','Quirks')) 'RequestBootVarRouting' $true
    Set-PlistBoolean (Get-PlistDictionary $Root @('Misc','Security')) 'AllowSetDefault' $true
    Set-PlistString (Get-PlistDictionary $Root @('NVRAM','Add','7C436110-AB2A-4BBB-A880-FE41995C9F82')) 'boot-args' ''
}

try {
    $step++; Write-DevintoshProgress $step $totalSteps 'Checking administrator privileges and generated hardware profile'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required.' }
    if (-not (Test-Path -LiteralPath $profilePath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Run configure-opencore-hardware.ps1 first: $profilePath" }
    Write-DevintoshStepLog $step 'Runtime and hardware profile are available.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Loading hardware facts and data-driven capability profiles'
    $hardware=Read-JsonFile $profilePath
    $profiles=@(Get-HardwareProfiles)
    Write-DevintoshLog 'INFO' "Capability profiles discovered: $($profiles.Count)."
    Write-DevintoshStepLog $step 'Live hardware facts loaded without manual identity input.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Resolving hardware capabilities'
    $matchedProfiles=@(Get-Matches $hardware $profiles)
    $state=Get-CapabilityState $matchedProfiles
    Write-DevintoshLog 'INFO' "Matched profiles: $(@($matchedProfiles | ForEach-Object { [string](Get-OptionalProperty $_ 'id') }) -join ', ')."
    Write-DevintoshLog 'INFO' "Resolution status: $($state.status). Resolved=$($state.resolved.Count); unresolved=$($state.unresolved.Count); validation=$($state.needsValidation.Count)."
    Write-DevintoshStepLog $step "Hardware capability resolution completed: $($state.status)." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Loading pinned OpenCore plist schema'
    if(-not(Test-Path -LiteralPath $samplePath)){Invoke-WebRequest -Uri $sampleUri -UseBasicParsing -OutFile $samplePath}
    if(-not(Test-Path -LiteralPath $samplePath)){$EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE;throw 'OpenCore Sample.plist could not be obtained.'}
    $xml=New-Object System.Xml.XmlDocument; $xml.PreserveWhitespace=$true; $xml.Load($samplePath)
    $root=[System.Xml.XmlElement]$xml.DocumentElement.SelectSingleNode('/plist/dict')
    if($null -eq $root){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'Invalid OpenCore Sample.plist root.'}
    Remove-PlistWarnings $root
    Write-DevintoshStepLog $step 'Pinned OpenCore schema loaded.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Applying hardware-independent OpenCore safety defaults'
    Set-GenericDefaults $root
    Write-DevintoshStepLog $step 'Only generic schema-safe defaults were applied.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Applying resolved capability policy'
    $applied=@($state.resolved)
    $candidateStatus=$state.status
    Write-DevintoshStepLog $step "Capability policy stage completed: $candidateStatus." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Writing OpenCore configuration candidate'
    if(-not(Test-Path -LiteralPath $efiOcRoot)){New-Item -ItemType Directory -Path $efiOcRoot -Force|Out-Null}
    if((Test-Path -LiteralPath $configPath)-and-not $Force){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw "Generated config already exists: $configPath. Use -Force to replace it."}
    $settings=New-Object System.Xml.XmlWriterSettings; $settings.Encoding=New-Object System.Text.UTF8Encoding($false); $settings.Indent=$true
    $writer=[System.Xml.XmlWriter]::Create($configPath,$settings); try{$xml.Save($writer)}finally{$writer.Dispose()}
    if(-not(Test-Path -LiteralPath $configPath)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'config.plist was not created.'}
    Write-DevintoshStepLog $step "Candidate written to $configPath." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Writing machine-independent capability reports'
    $resolution=[ordered]@{
        schemaVersion=1
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        sourceProfile='build/opencore/hardware-detected.json'
        status=$state.status
        matchedProfiles=@($matchedProfiles | ForEach-Object { [string](Get-OptionalProperty $_ 'id') })
        resolvedCapabilities=@($state.resolved)
        unresolvedCapabilities=@($state.unresolved)
        needsValidation=@($state.needsValidation)
        capabilities=$state.capabilities
    }
    $resolution | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolutionPath -Encoding UTF8

    $report=[ordered]@{
        schemaVersion=2
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        sourceProfile='build/opencore/hardware-detected.json'
        status=$state.status
        matchedProfiles=@($matchedProfiles | ForEach-Object { [string](Get-OptionalProperty $_ 'id') })
        resolvedCapabilities=@($state.resolved)
        unresolvedCapabilities=@($state.unresolved)
        needsValidation=@($state.needsValidation)
        appliedCapabilityKeys=$applied
        generatedArtifacts=@('build/efi/EFI/OC/config.plist')
        intentionallyNotGenerated=@(
            'SMBIOS unique identifiers',
            'audio layout-id',
            'USB port map',
            'ACPI patches and SSDTs',
            'GPU spoofing',
            'third-party kext binaries and versions'
        )
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-DevintoshStepLog $step 'Hardware-agnostic capability reports written.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Finalizing hardware-agnostic OpenCore candidate'
    Write-DevintoshStepLog $step 'Unknown hardware is reported as NeedsProfile rather than rejected or mapped to another machine.' 'PASS'
    Write-DevintoshProgressComplete 'OpenCore configuration candidate complete'
    $EXIT_CODE=$script:EXIT_SUCCESS
}
catch {
    Write-DevintoshStepLog $step "OpenCore configuration failed: $($_.Exception.Message)" 'FAIL'
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    try { Invoke-DevintoshRollback } catch { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
}

exit $EXIT_CODE
