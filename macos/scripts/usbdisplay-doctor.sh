#!/usr/bin/env bash
# Read-only environment checks. Does not install tools or change system settings.
set -uo pipefail
JSON=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --check|--no-color) ;;
    --yes|-y) printf '%s\n' '--yes no longer installs tools; use the explicit instructions below.' >&2 ;;
    --help|-h) printf '%s\n' 'usbdisplay-doctor.sh [--check] [--json]: read-only environment checks'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done
OS=0; SWIFT=0; USB=0
[ "$(uname -s)" = Darwin ] && OS=1
command -v swift >/dev/null 2>&1 && SWIFT=1
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libusb-1.0; then USB=1; fi
if [ "$JSON" = 1 ]; then
  printf '{"macos":%s,"swift":%s,"libusb":%s,"hardwareTested":false}\n' \
    "$([ "$OS" = 1 ] && echo true || echo false)" \
    "$([ "$SWIFT" = 1 ] && echo true || echo false)" \
    "$([ "$USB" = 1 ] && echo true || echo false)"
else
  printf 'macOS: %s · Swift: %s · libusb: %s\n' "$OS" "$SWIFT" "$USB"
  [ "$OS" = 1 ] || printf '%s\n' 'Run these commands on your Mac, not on Windows/Linux.'
  [ "$SWIFT" = 1 ] || printf '%s\n' 'Install manually: xcode-select --install'
  [ "$USB" = 1 ] || printf '%s\n' 'Install manually: brew install libusb pkg-config'
  printf '%s\n' 'Grant Screen Recording to your terminal, then restart it.' \
    'For touch input, grant Accessibility to the terminal.' \
    'Connect exactly one unlocked Android phone with the APK installed and a data cable.' \
    'AOA mode alone does NOT prove the APK is installed or video is working.' \
    'Next: bash macos/scripts/usbdisplay-run.sh' \
    'Hardware validation: docs/TESTING.zh-CN.md'
fi
[ "$OS" = 1 ] && [ "$SWIFT" = 1 ] && [ "$USB" = 1 ]
