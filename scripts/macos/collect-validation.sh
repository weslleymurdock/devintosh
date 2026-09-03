#!/bin/bash
set -u

# Devintosh native macOS validation collector.
# This script is intentionally read-only: it collects runtime evidence and never
# changes OpenCore, NVRAM, ACPI, USB mappings, kexts, network settings or audio settings.

SCRIPT_VERSION="1.0.2"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
ROOT="${HOME}/Desktop/devintosh-macos-validation-${STAMP}"
EVIDENCE="${ROOT}/evidence"
mkdir -p "${EVIDENCE}"

log() { printf '[DEVINTOSH] %s\n' "$1"; }

sanitize() {
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
    set +e
    "$@" 2>&1 | sanitize > "${EVIDENCE}/${name}.txt"
    command_status=${PIPESTATUS[0]}
    set -u
    printf '%s\n' "$command_status" > "${EVIDENCE}/${name}.exitcode"
    if [ "$command_status" -ne 0 ]; then
        log "WARN: ${name} exited with ${command_status}; evidence was preserved."
    fi
}

capture_shell() {
    name="$1"
    shift
    log "Collecting ${name}"
    set +e
    /bin/bash -c "$*" 2>&1 | sanitize > "${EVIDENCE}/${name}.txt"
    command_status=${PIPESTATUS[0]}
    set -u
    printf '%s\n' "$command_status" > "${EVIDENCE}/${name}.exitcode"
    if [ "$command_status" -ne 0 ]; then
        log "WARN: ${name} exited with ${command_status}; evidence was preserved."
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

set +e
/usr/sbin/system_profiler SPDisplaysDataType 2>&1 | sanitize | grep -Ei 'Metal Support|Metal Family|Metal' > "${EVIDENCE}/metal-observation.txt"
metal_status=${PIPESTATUS[0]}
set -u
if [ "$metal_status" -eq 0 ]; then metal_observed="observed"; else metal_observed="not-observed"; fi

if /usr/sbin/nvram -p 2>/dev/null | sanitize | grep -Ei '^(boot-args|4D1EDE05-38C7-4A6A-9CC6-4BCCA8B30102:boot-args)' > "${EVIDENCE}/boot-args.txt"; then
    true
else
    printf 'boot-args not available or not present.\n' > "${EVIDENCE}/boot-args.txt"
fi

MANIFEST_PLIST="${ROOT}/manifest.plist"
/usr/libexec/PlistBuddy -c "Add :schemaVersion integer 1" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :collectorVersion string ${SCRIPT_VERSION}" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :generatedAtUtc date $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :osVersion string $(sw_vers -productVersion 2>/dev/null || echo unknown)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :buildVersion string $(sw_vers -buildVersion 2>/dev/null || echo unknown)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :kernelVersion string $(uname -r)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :machine string $(sysctl -n hw.machine 2>/dev/null || echo unknown)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :model string $(sysctl -n hw.model 2>/dev/null || echo unknown)" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :metalObservation string ${metal_observed}" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :readOnly bool true" "$MANIFEST_PLIST"
/usr/libexec/PlistBuddy -c "Add :privacyRedacted bool true" "$MANIFEST_PLIST"
/usr/bin/plutil -convert json -o "${ROOT}/manifest.json" "$MANIFEST_PLIST"
rm -f "$MANIFEST_PLIST"

cat > "${ROOT}/validation-results.json" <<'EOF'
{
  "gpu": false,
  "smbios": false,
  "acpi": false,
  "usb": false,
  "network": false,
  "audio": false,
  "kexts": false
}
EOF

(
    cd "$ROOT" || exit 1
    /usr/bin/shasum -a 256 evidence/* validation-results.json > SHA256SUMS
)

cat > "${ROOT}/VALIDATION-CHECKLIST.md" <<'EOF'
# Devintosh native macOS validation checklist

This bundle contains read-only evidence collected from the running macOS installation.
Do not edit evidence files directly. Use `finalize-validation.sh` to record tests that were actually performed.

## Automated observations

- macOS version and kernel were captured.
- Graphics/Displays and Metal observations were captured.
- USB topology was captured from System Information and IORegistry.
- Audio devices/codecs were captured.
- Network interfaces/controllers were captured with MAC addresses redacted.
- ACPI IORegistry information was captured.
- Loaded kext information was captured.
- Effective NVRAM boot arguments were captured with unique identifiers redacted.

## Required runtime validation

Evidence collection alone does NOT prove compatibility. Test the following on the running system:

1. GPU: expected display output, acceleration/Metal, stable graphics and sleep/wake when required.
2. SMBIOS: selected model is the intended candidate; never copy unique SMBIOS identifiers into this bundle.
3. ACPI: expected devices and power management work; investigate recurring ACPI errors.
4. USB: required physical ports/devices work and topology behaves correctly across sleep/wake.
5. Network: intended wired/wireless controller provides connectivity and survives relevant power-state transitions.
6. Audio: intended input/output devices work, including microphone when required.
7. Kexts: expected third-party kexts load without recurring kernel faults attributable to them.

After completing the tests, run `finalize-validation.sh` with one or more capability names. The script updates
`validation-results.json` and regenerates `SHA256SUMS`, so the importer can verify the complete bundle.
EOF

cat > "${ROOT}/finalize-validation.sh" <<'EOF'
#!/bin/bash
set -u

# Explicitly records runtime tests that the operator actually completed.
# This script changes only the validation bundle, never the running system.

ROOT="$(cd "$(dirname "$0")" && pwd)"
RESULTS="${ROOT}/validation-results.json"

usage() {
    echo "Usage: $0 [--gpu] [--smbios] [--acpi] [--usb] [--network] [--audio] [--kexts]"
    exit 2
}

[ -f "$RESULTS" ] || { echo "validation-results.json not found" >&2; exit 4; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --gpu) /usr/bin/plutil -replace gpu -bool YES "$RESULTS" ;;
        --smbios) /usr/bin/plutil -replace smbios -bool YES "$RESULTS" ;;
        --acpi) /usr/bin/plutil -replace acpi -bool YES "$RESULTS" ;;
        --usb) /usr/bin/plutil -replace usb -bool YES "$RESULTS" ;;
        --network) /usr/bin/plutil -replace network -bool YES "$RESULTS" ;;
        --audio) /usr/bin/plutil -replace audio -bool YES "$RESULTS" ;;
        --kexts) /usr/bin/plutil -replace kexts -bool YES "$RESULTS" ;;
        *) usage ;;
    esac
    shift
done

(
    cd "$ROOT" || exit 1
    /usr/bin/shasum -a 256 evidence/* validation-results.json > SHA256SUMS
)

echo "Validation results recorded and SHA256SUMS regenerated."
EOF
chmod +x "${ROOT}/finalize-validation.sh"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$ROOT" "${ROOT}.zip"
log "Validation bundle: ${ROOT}.zip"
log "Transfer the ZIP to Windows and import it with import-macos-validation.ps1."
exit 0
