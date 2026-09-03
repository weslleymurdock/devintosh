#requires -Version 5.1
<#
.SYNOPSIS
    Generic data-driven OpenCore profile fragment engine.

.DESCRIPTION
    Applies declarative OpenCore plist fragments supplied by matched hardware profiles.
    The engine contains no hardware-specific identifiers or decision branches.

    Profiles may provide an `opencore.plist` object whose leaves are typed descriptors:
      { "type": "boolean", "value": true }
      { "type": "integer", "value": 1 }
      { "type": "string",  "value": "text" }
      { "type": "data",    "value": "AABB", "format": "hex" }

    `opencore.policy = validation-required` prevents all profile fragments from being
    applied. This guarantees that a detected-but-unvalidated device cannot silently
    receive an unsafe configuration.

    The engine detects conflicting writes to the same plist path before applying them.
#>

Set-StrictMode -Version Latest

function Get-ProfileProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ProfileArray {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-PlistDictionaryAtPath {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Root,
        [Parameter(Mandatory)][string[]]$Path
    )

    $current = $Root
    foreach ($name in $Path) {
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'OpenCore plist path contains an empty component.' }
        $key = $null
        $node = $current.FirstChild
        while ($null -ne $node) {
            if ($node.NodeType -eq 'Element' -and $node.Name -eq 'key' -and $node.InnerText -eq $name) {
                $key = $node
                break
            }
            $node = $node.NextSibling
        }

        if ($null -ne $key) {
            $value = $key.NextSibling
            while ($null -ne $value -and $value.NodeType -ne 'Element') { $value = $value.NextSibling }
            if ($null -eq $value -or $value.Name -ne 'dict') {
                throw "OpenCore plist path '$($Path -join '/')' contains non-dictionary key '$name'."
            }
            $current = [System.Xml.XmlElement]$value
            continue
        }

        $newKey = $current.OwnerDocument.CreateElement('key')
        $newKey.InnerText = $name
        [void]$current.AppendChild($newKey)
        $newDict = $current.OwnerDocument.CreateElement('dict')
        [void]$current.AppendChild($newDict)
        $current = $newDict
    }
    return $current
}

function Convert-HexToBase64 {
    param([Parameter(Mandatory)][string]$Hex)
    $normalized = $Hex.Trim().Replace('0x','').Replace(' ','').Replace('-','')
    if ($normalized.Length -eq 0) { return '' }
    if (($normalized.Length % 2) -ne 0 -or $normalized -notmatch '^[0-9A-Fa-f]+$') {
        throw "Invalid hexadecimal plist data: '$Hex'."
    }
    $bytes = New-Object byte[] ($normalized.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($normalized.Substring($i * 2, 2), 16)
    }
    return [Convert]::ToBase64String($bytes)
}

function New-PlistValueElement {
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)]$Descriptor
    )

    $type = [string](Get-ProfileProperty $Descriptor 'type')
    $value = Get-ProfileProperty $Descriptor 'value'
    if ([string]::IsNullOrWhiteSpace($type)) { throw 'OpenCore plist descriptor is missing type.' }

    switch ($type.ToLowerInvariant()) {
        'boolean' {
            if ($value -isnot [bool]) { throw "OpenCore boolean descriptor requires a JSON boolean value." }
            $element = $Document.CreateElement($(if ($value) { 'true' } else { 'false' }))
        }
        'integer' {
            $number = 0L
            if (-not [long]::TryParse([string]$value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                throw "Invalid OpenCore integer value '$value'."
            }
            $element = $Document.CreateElement('integer')
            $element.InnerText = [string]$number
        }
        'string' {
            $element = $Document.CreateElement('string')
            $element.InnerText = if ($null -eq $value) { '' } else { [string]$value }
        }
        'data' {
            $format = [string](Get-ProfileProperty $Descriptor 'format')
            $text = if ($null -eq $value) { '' } else { [string]$value }
            if ($format -eq 'hex') { $text = Convert-HexToBase64 $text }
            elseif ($format -ne 'base64') { throw "Unsupported OpenCore data format '$format'. Use 'hex' or 'base64'." }
            $element = $Document.CreateElement('data')
            $element.InnerText = $text
        }
        default { throw "Unsupported OpenCore plist descriptor type '$type'." }
    }
    return $element
}

function Set-PlistLeafValue {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Root,
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)]$Descriptor
    )

    if ($Path.Count -lt 1) { throw 'OpenCore plist leaf path cannot be empty.' }
    $parent = if ($Path.Count -eq 1) { $Root } else { Get-PlistDictionaryAtPath $Root $Path[0..($Path.Count - 2)] }
    $name = $Path[$Path.Count - 1]

    $key = $null
    $node = $parent.FirstChild
    while ($null -ne $node) {
        if ($node.NodeType -eq 'Element' -and $node.Name -eq 'key' -and $node.InnerText -eq $name) { $key = $node; break }
        $node = $node.NextSibling
    }

    $value = New-PlistValueElement $Root.OwnerDocument $Descriptor
    if ($null -eq $key) {
        $key = $parent.OwnerDocument.CreateElement('key')
        $key.InnerText = $name
        [void]$parent.AppendChild($key)
        [void]$parent.AppendChild($value)
        return
    }

    $old = $key.NextSibling
    while ($null -ne $old -and $old.NodeType -ne 'Element') { $old = $old.NextSibling }
    if ($null -ne $old) { [void]$parent.RemoveChild($old) }
    [void]$parent.InsertAfter($value, $key)
}

function Get-PlistFragmentLeaves {
    param(
        [Parameter(Mandatory)]$Object,
        [string[]]$Path = @()
    )

    $properties = @($Object.PSObject.Properties)
    if ($properties.Count -eq 0) { return @() }

    $leaves = [System.Collections.Generic.List[object]]::new()
    foreach ($property in $properties) {
        $name = [string]$property.Name
        $value = $property.Value
        if ($null -eq $value) { throw "OpenCore plist fragment '$($Path -join '/')/$name' is null." }

        $type = Get-ProfileProperty $value 'type'
        if ($null -ne $type) {
            [void]$leaves.Add([pscustomobject]@{ Path = @($Path + $name); Descriptor = $value })
        }
        else {
            foreach ($leaf in @(Get-PlistFragmentLeaves $value @($Path + $name))) { [void]$leaves.Add($leaf) }
        }
    }
    return @($leaves.ToArray())
}

function Get-DescriptorFingerprint {
    param([Parameter(Mandatory)]$Descriptor)
    return ($Descriptor | ConvertTo-Json -Compress -Depth 10)
}

function Get-ProfilePlistOperations {
    param([AllowNull()][object[]]$Profiles)

    $operations = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in @(Get-ProfileArray $Profiles)) {
        $openCore = Get-ProfileProperty $profile 'opencore'
        if ($null -eq $openCore) { continue }
        $policy = [string](Get-ProfileProperty $openCore 'policy')
        if ($policy -eq 'validation-required') { continue }
        $fragment = Get-ProfileProperty $openCore 'plist'
        if ($null -eq $fragment) { continue }

        $profileId = [string](Get-ProfileProperty $profile 'id')
        foreach ($leaf in @(Get-PlistFragmentLeaves $fragment)) {
            [void]$operations.Add([pscustomobject]@{
                ProfileId = $profileId
                Path = @($leaf.Path)
                Descriptor = $leaf.Descriptor
                Fingerprint = Get-DescriptorFingerprint $leaf.Descriptor
            })
        }
    }
    return @($operations.ToArray())
}

function Apply-OpenCoreProfileFragments {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Root,
        [AllowNull()][object[]]$Profiles
    )

    $operations = @(Get-ProfilePlistOperations $Profiles)
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $accepted = [System.Collections.Generic.List[object]]::new()
    $byPath = @{}

    foreach ($operation in $operations) {
        $pathKey = ($operation.Path -join '/')
        if ($byPath.ContainsKey($pathKey)) {
            $existing = $byPath[$pathKey]
            if ($existing.Fingerprint -ne $operation.Fingerprint) {
                [void]$conflicts.Add([pscustomobject]@{
                    path = $pathKey
                    firstProfile = $existing.ProfileId
                    secondProfile = $operation.ProfileId
                })
                continue
            }
            continue
        }
        $byPath[$pathKey] = $operation
        [void]$accepted.Add($operation)
    }

    if ($conflicts.Count -gt 0) {
        return [pscustomobject]@{
            status = 'Conflict'
            applied = @()
            conflicts = @($conflicts.ToArray())
            skippedValidation = @()
        }
    }

    foreach ($operation in $accepted) {
        Set-PlistLeafValue $Root $operation.Path $operation.Descriptor
    }

    $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($profile in @(Get-ProfileArray $Profiles)) {
        $openCore = Get-ProfileProperty $profile 'opencore'
        if ($null -ne $openCore -and [string](Get-ProfileProperty $openCore 'policy') -eq 'validation-required') {
            [void]$skipped.Add([string](Get-ProfileProperty $profile 'id'))
        }
    }

    return [pscustomobject]@{
        status = 'Applied'
        applied = @($accepted | ForEach-Object { [pscustomobject]@{ profile = $_.ProfileId; path = ($_.Path -join '/') } })
        conflicts = @()
        skippedValidation = @($skipped)
    }
}
