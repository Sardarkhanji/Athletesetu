# AthleteSetu

AthleteSetu is an offline-first Flutter app that digitises the **SAI 10-battery fitness assessment**. It uses on-device computer vision: MoveNet pose estimation through TFLite, marker calibration, and timing gates.

- **Platforms:** Android 10+ (minSdk 29) and iOS 14+
- **Data:** athlete data is stored in an AES-256 SQLCipher database and never leaves the phone
- **Languages:** English and Hindi (EN | हिं toggle)
- **Demo Simulation Mode:** every test can be run end-to-end with no camera setup

## Requirements

| Tool | Version |
|------|---------|
| Flutter | **3.41.5** (stable), with Dart 3.11.3 |
| JDK | 17 |
| Android SDK | platform and build-tools for the Flutter default `compileSdk`, plus NDK (Flutter installs it on first build) |
| Xcode + CocoaPods | only for iOS builds; macOS only |

## Run locally

```bash
git clone https://github.com/Sardarkhanji/Athletesetu.git
cd Athletesetu
./scripts/bootstrap.sh      # checks the toolchain, runs pub get, analyze and tests
flutter run                 # with an Android phone connected over USB (debugging on)
```

Or step by step:

```bash
flutter pub get
flutter analyze
flutter test                # 10 engine accuracy tests on synthetic data
flutter run
```

The model (`assets/models/movenet_lightning_int8.tflite`) and fonts (`assets/fonts/`) are committed, so nothing else needs downloading.

### Linux: let adb see the phone

```bash
# 2717 = Xiaomi/Redmi. Add a line per vendor (Samsung 04e8, Google 18d1, OnePlus 2a70, ...)
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="2717", MODE="0666", GROUP="plugdev"' \
  | sudo tee /etc/udev/rules.d/51-android.rules
sudo udevadm control --reload-rules && sudo usermod -aG plugdev "$USER"
# log out and back in, reconnect the phone, accept the USB-debugging prompt
adb devices
```

On Xiaomi/Redmi, also enable **Install via USB** in Developer options. Enable **USB debugging (Security settings)** too if you want `adb` taps to work.

## Release build

```bash
flutter build apk --release --split-per-abi
# build/app/outputs/flutter-apk/app-arm64-v8a-release.apk     (most phones)
# build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk   (old 32-bit phones)
```

### Signing

- **Without a key:** release builds fall back to the debug key, which is fine for local testing.
- **For builds testers install over v1.0.0:** you need the original upload key.
  1. Get `upload-keystore.jks` and the passwords from the project owner, over a private channel.
  2. Put the keystore at `android/app/upload-keystore.jks`.
  3. Copy `android/key.properties.example` to `android/key.properties` and fill in the passwords.

Both files are git-ignored. **Never commit them.** Android won't let you install an update signed with a different key over the existing app, so users would have to uninstall first and lose their data.

Before each release, bump `version:` in `pubspec.yaml`.

## Project layout

```
lib/
  core/        theme, encrypted database + repository, localization (EN/HI), permissions, shared widgets
  engines/     pure-Dart measurement engines + TFLite isolate
    isolate_runner.dart        camera frame → YUV/BGRA convert → MoveNet (NNAPI/CPU auto-benchmark)
    calibration_engine.dart    marker detection, homography, px/cm, level (±2°), FPS meter
    jump_reach_engine.dart     height, vertical jump, broad jump, sit & reach
    pose_fsm_engine.dart       sit-ups state machine with foul rejection
    timing_gate_engine.dart    sprint / shuttle / endurance gates, 2-phone UDP clock sync
    assisted_ocr_engine.dart   weight seven-segment OCR, medicine-ball landing
  features/    mode_selection, registration (DPDP consent), assessment_hub,
               camera_workbench (camera + HUD + simulation), reports_sync (PDF, recycle bin)
test/          engine simulation tests (synthetic poses through a pinhole camera model)
assets/        MoveNet model, Noto Sans + Noto Sans Devanagari fonts
docs/          tester notes
```

## Accuracy on simulated data (`flutter test`)

| Test | Target | Simulated error |
|------|--------|-----------------|
| Height | ±1 cm | ≤0.5 cm |
| Vertical jump | ±2 cm | ≤0.21 cm |
| Broad jump | ±2 cm | ≤0.53 cm |
| Sit & reach | ±2 cm | ~0.1 cm |
| Sit-ups | exact | 100 % |
| Sprint / shuttle | — | ≤14 ms |
| Medicine ball | — | ≤1.7 cm |

Accuracy on real athletes has not been validated yet. See [docs/TESTING.md](docs/TESTING.md).

## Notes

- **Hindi in PDFs:** the `pdf` package can't shape Devanagari, so `pdf_report_service.dart` renders Hindi text with Flutter's text engine and embeds it as images.
- **NNAPI:** do not attach tflite_flutter's `XNNPackDelegate` explicitly. It segfaults on Android. The isolate benchmarks CPU (2 or 4 threads) and NNAPI, then keeps the fastest.
- **Dependency pins:** `permission_handler` is pinned to `^12.0.1` (v14 breaks the AGP Kotlin DSL build) and `image` to `4.5.4` (newer versions need a newer `archive`).
