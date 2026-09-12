# Android USB Mac Display

[简体中文](README.md) · Built by [ConfigCrate](https://configcrate.com/).

Experimental Mac-to-Android display over a USB data cable. **Hardware validation pending; not a stable release.**

Default: main-screen mirroring, 1280×720, 30 fps, 8 Mbps. Optional `--backend virtual` creates an experimental extended desktop using private CGVirtualDisplay APIs; failure is explicit, with no silent mirror fallback.

Requires macOS 13+, Xcode Command Line Tools, Homebrew libusb/pkg-config, Android 8+ with AOA support, the Android APK, and a data cable. AOA does not require USB debugging.

```bash
brew install libusb pkg-config
git clone https://github.com/configcrate/android-usb-mac-display.git
cd android-usb-mac-display
bash macos/scripts/usbdisplay-run.sh
```

Install the APK from a successful Actions run's android-debug-apk artifact. Grant Screen Recording to your terminal and restart it. Unlock the phone and grant USB accessory permission. Grant Accessibility to the terminal for one-finger mouse clicks/drags. Ctrl-C releases resources.

Connect one Android at a time and quit USB file-transfer apps. On disconnect, reconnect the cable and rerun the host. Host artifacts still depend on Homebrew libusb paths; build from source for your architecture.

CI builds both Mac architectures and Android, tests production streaming parsers, and runs Android lint. Actual USB ownership, device compatibility, virtual-display behaviour, heat and display latency still require hardware tests. USB RTT is not glass-to-glass latency; there is no measured 25ms/60fps/4K guarantee.

No developer-signed/notarized Mac installer or production-signed Android APK yet. Single-finger mouse support only; no keyboard, multitouch, audio, or App Store support promised. No cloud, account or telemetry. Connect trusted devices only: your screen content is transmitted to Android.

[Hardware test checklist (Chinese)](docs/TESTING.zh-CN.md). Earlier architecture documents describe design goals, not verified capabilities.

MIT license for this project. libusb is a separate dynamically linked LGPL-2.1-or-later dependency.
Original project: [CNB](https://cnb.cool/ConfigCrate/android-usb-mac-display).

