#!/bin/bash
set -u

# Devintosh native macOS validation collector.
# This script is intentionally read-only: it collects runtime evidence and never
# changes OpenCore, NVRAM, ACPI, USB mappings, kexts, network settings or audio settings.

SCRIPT_VERSION="1.0.0"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
ROOT="${HOME}/Desktop/devintosh-macos-validation-${STAMP}"
EVIDENCE="${ROOT}/evidence"
mkdir -p "${EVIDENCE}"

log() { printf '[DEVINTOSH] %s\n' "$1"; }

sanitize() {
    # Keep evidence useful while removing unique identifiers and network addresses.
    sed -E \
        -e 's/([Ss]erial([[:space:]_-]*[Nn]umber)?)[[:space:]]*:[[:space:]]*.*/\1: <REDACTED>/g' \
        -e 's/([Hh]ardware|[Pp]latform)[[:space:]_-]*UUID[[:space:]]*:[[:space:]]*.*/\1 UUID: <REDACTED>/g' \
        -e 's/([Mm]ac|[Ee]thernet)[[:space:]_-]*(Address|ID)[[:space:]]*:[[:space:]]*.*/\1 Address: <REDACTED>/g' \
        -e 's/([Mm]acAddress|[Hh]ardwareAddress|[Ee]thernetAddress)[[:space:]]*=[[:space:]]*[^[:space:]]+/\1=<REDACTED>/g' \
        -e 's/[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}/<REDACTED-MAC>/g'
}

capture() {
    name="$1"
    shift
    log "Collecting ${name}"
    if "$@" 2>&1 | sanitize > "${EVIDENCE}/${name}.txt"; then
        printf '0\n' > "${EVIDENCE}/${name}.exitcode"
    else
        code=$?
        printf '%s\n' "$code" > "${EVIDENCE}/${name}.exitcode"
        log "WARN: ${name} exited with ${code}; evidence was preserved."
    fi
}

capture_shell() {
    name="$1"
    shift
    log "Collecting ${name}"
    if /bin/bash -c "$*" 2>&1 | sanitize > "${EVIDENCE}/${name}.txt"; then
        printf '0\n' > "${EVIDENCE}/${name}.exitcode"
    else
        code=$?
        printf '%s\n' "$code" > "${EVIDENCE}/${name}.exitcode"
        log "WARN: ${name} exited with ${code}; evidence was preserved."
    fi
}

capture system_profiler /usr/sbin/system_profiler SPSoftwareDataType
capture hardware /usr/sbin/system_profiler SPHardwareDataType
capture displays /usr/sbin/system_profiler SPDisplaysDataType
capture usb /usr/sbin/system_profiler SPUSBDataType
capture audio /usr/sbin/system_profiler SPAudioDataType
capture network /usr/sbin/system_profiler SPNetworkDataType
capture acpi /usr/sbin/ioreg -l -p IOACPIPlane
capture usb-ioreg /usr/sbin/ioreg -l -p IOUSB -w 0
capture pci-ioreg /usr/sbin/ioreg -l -p IOService -w 0
capture kexts /usr/bin/kmutil showloaded --list-only
capture diskutil /usr/sbin/diskutil list
capture nvram /usr/sbin/nvram -p
capture_shell sysctl 'sysctl -a | grep -E "^(hw\\.model|hw\\.machine|machdep\\.cpu|kern\\.osproductversion|kern\\.osrelease)"'

# Objective display/Metal observation. Apple documents System Information > Graphics/Displays
# as the source of truth for Metal support; this collector records the same subsystem data.
if /usr/sbin/system_profiler SPDisplaysDataType 2>&1 | sanitize | grep -Ei 'Metal Support|Metal Family|Metal' > "${EVIDENCE}/metal-observation.txt"; then
    metal_status="observed"
else
    metal_status="not-observed"
fi

# Record OpenCore's effective boot arguments if available, with unique identifiers removed.
if /usr/sbin/nvram -p 2>/dev/null | sanitize | grep -Ei '^(boot-args|4D1EDE05-38C7-4A6A-9CC6-4BCCA8B30102:boot-args)' > "${EVIDENCE}/boot-args.txt"; then
    true
else
    printf 'boot-args not available or not present.\n' > "${EVIDENCE}/boot-args.txt"
fi

# Build a plist manifest so no non-standard JSON utility is required on macOS.
MANIFEST_PLIST="${ROOT}/manifest.plist"
/usr/libexec/PlistBuddy -c "Add :schemaVersion integer 1" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :collectorVersion string ${SCRIPT_VERSION}" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :generatedAtUtc date $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :hostname string $(scutil --get LocalHostName 2>/dev/null || echo unknown)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :osVersion string $(sw_vers -productVersion 2>/dev/null || echo unknown)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :buildVersion string $(sw_vers -buildVersion 2>/dev/null || echo unknown)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :kernelVersion string $(uname -r)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :machine string $(sysctl -n hw.machine 2>/dev/null || echo unknown)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :model string $(sysctl -n hw.model 2>/dev/null || echo unknown)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :metalObservation string ${metal_status}" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :readOnly bool true" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :privacyRedacted bool true" "$MANIFEST_PLIST"
/usr/bin/plutil -convert json -o "${ROOT}/manifest.json" "$MANIFEST_PLIST"
rm -f "$MANIFEST_PLIST"

# SHA-256 covers every collected evidence file and makes the import deterministic.
(
    cd "$ROOT" || exit 1
    /usr/bin/shasum -a 256 evidence/* > SHA256SUMS
)

# Include a human-readable validation checklist. The collector never marks these
# runtime behaviours as passed merely because a device is visible.
cat > "${ROOT}/VALIDATION-CHECKLIST.md" <<'EOF'
# Devintosh native macOS validation checklist

This bundle contains read-only evidence collected from the running macOS installation.
Do not edit evidence files before importing them.

## Automated observations

- macOS version and kernel were captured.
- Graphics/Displays information and Metal observation were captured.
- USB topology information was captured from System Information and IORegistry.
- Audio devices/codecs were captured.
- Network interfaces/controllers were captured with MAC addresses redacted.
- ACPI IORegistry information was captured.
- Loaded kext information was captured.
- Effective NVRAM boot arguments were captured with unique identifiers redacted.

## Required human/runtime validation

Evidence collection alone does NOT prove that a capability is operational.
Before accepting a capability as validated, verify the corresponding runtime behaviour:

1. GPU: expected display output, acceleration/Metal, sleep/wake and no recurring graphics/kernel faults.
2. SMBIOS: selected model is the intended candidate; do not copy or generate unique SMBIOS identifiers from evidence.
3. ACPI: no required device disappears or develops repeated ACPI errors; sleep/wake must be tested where applicable.
4. USB: all required ports/devices work and sleep/wake does not expose incorrect or duplicated ports.
5. Network: the intended wired/wireless controller obtains connectivity and survives sleep/wake where applicable.
6. Audio: intended input/output devices work, including microphone if required.
7. Kexts: expected third-party kexts are loaded and no recurring kernel faults are attributed to them.

A future validation importer may only promote a capability when both machine evidence and
an explicit validation result are present. This collector intentionally does not fabricate
those results.
EOF

# Package with native macOS tooling for easy transfer to Windows.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$ROOT" "${ROOT}.zip"
log "Validation bundle: ${ROOT}.zip"
log "Transfer the ZIP to the Windows project workspace and import it with import-macos-validation.ps1."
exit 0
