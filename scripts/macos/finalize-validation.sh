#!/bin/bash
set -u

# Records only runtime tests explicitly confirmed by the operator.
# This script modifies the validation bundle only; it never changes the running system.

ROOT="$(cd "$(dirname "$0")" && pwd)"
RESULTS="${ROOT}/validation-results.json"
ZIP="${ROOT}.zip"

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

rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$ROOT" "$ZIP"

echo "Validation results recorded and SHA256SUMS regenerated."
echo "Updated validation bundle: $ZIP"
