# AthleteSetu: notes for Claude Code sessions

Flutter 3.41.5 / Dart 3.11.3. Uses Riverpod 2.6 (Notifier / FutureProvider) and go_router 17. Read `README.md` for setup and layout.

## Commands
- `flutter analyze` must stay clean (zero issues).
- `flutter test` runs 10 engine simulation tests, all passing as of v1.0.0.
- `flutter build apk --release --split-per-abi` builds the release APKs.

## Architecture rules
- **Engines** (`lib/engines/`) are pure Dart and use image-pixel coordinates (`Vec2`, `PoseFrame`).
  - Each test has a `MeasurementSession` plus a `FrameSimulator`.
  - Simulators render a humanoid rig through a pinhole `SimCamera`, so the real algorithms run on synthetic frames.
  - Any accuracy change must keep `test/engines_simulation_test.dart` green.
- **Calibration:**
  - Wall and box markers use a reflection-similarity fit. Don't switch them to a full homography: four noisy corners distort scale.
  - Floor tests use a DLT homography plus `LineProjectiveMap`.
- **TFLite** runs in an isolate (`isolate_runner.dart`).
  - Rotation and mirroring are folded into a single integer affine sampler.
  - The isolate benchmarks `cpu2`, `cpu4` and `nnapi` and caches the winner.
  - Never attach `XNNPackDelegate` explicitly: it causes a native SIGSEGV on Android.
- **Database:** SQLCipher, with the key in flutter_secure_storage and WAL turned on via `rawQuery`.
  - Scores and videos live in separate tables.
  - Deletes are soft, with a 30-day recycle-bin purge.
- **Consent:** the `/workbench/...` route redirects unless `hasValidConsent`. Minors need a guardian name, the relationship and a photo of the signed form.
- **Overrides:** manual overrides on the confirm sheet are stored as training labels.
- **UI:**
  - Palette is defined in `core/theme/app_theme.dart`; no gradients.
  - Use tabular figures for metrics, 48 px minimum touch targets and bottom-anchored primary buttons.
  - Text scale is clamped to 1.3.
- **Strings:** every user-facing string goes in `core/localization/strings.dart`, in both EN and HI.
- **Logging:** `CameraPipeline.log()` writes `[AthleteSetu] ...` lines. Filter with `adb logcat | grep AthleteSetu`.

## State as of v1.0.0 (2026-11-07)
- **Released:** v1.0.0 (versionCode 2001 arm64) was installed on a Redmi (Android 10+, MIUI).
- **Verified on device:** all 9 camera tests in Demo Simulation; camera at 1280×720 YUV420; model input upright with correct colours.
  - NNAPI pose time: about 24 ms cold, 57–110 ms when the phone is hot.
  - Camera frame rate indoors: 11–28 FPS.
- **Not yet verified:**
  - The release (R8-minified) build with the real camera and TFLite path.
  - A real athlete in frame.
  - Printed-marker calibration.
  - Weight OCR and PDF export on the phone.
- **Ideas:** adaptive frame-skipping for timing tests when the phone is hot.

## Signing
`android/app/upload-keystore.jks` and `android/key.properties` are git-ignored and are never committed. Without them, release builds fall back to the debug key, which is fine locally. Testers who already have v1.0.0 can only upgrade to builds signed with the original key.

## Gotchas
- MIUI blocks `adb shell input` until "USB debugging (Security settings)" is enabled.
- `permission_handler` is pinned to `^12.0.1` and `image` to `4.5.4`. Don't bump either without testing the Android build.
