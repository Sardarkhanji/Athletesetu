#!/usr/bin/env bash
# Checks the toolchain and prepares the project. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

want_flutter="3.41.5"

if ! command -v flutter >/dev/null 2>&1; then
  echo "✗ flutter not found on PATH. Install Flutter $want_flutter: https://docs.flutter.dev/get-started/install"
  exit 1
fi

have_flutter="$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')"
if [[ "$have_flutter" != "$want_flutter" ]]; then
  echo "! Flutter $have_flutter found; this project was built and tested with $want_flutter."
fi

if command -v java >/dev/null 2>&1; then
  java -version 2>&1 | head -1
else
  echo "! java not found. Android builds need JDK 17."
fi

if [[ ! -f android/key.properties ]]; then
  echo "• No android/key.properties: release builds will use the debug key (fine for local testing)."
fi

echo "→ flutter pub get";  flutter pub get
echo "→ flutter analyze";  flutter analyze
echo "→ flutter test";     flutter test

echo
echo "✓ Ready. Connect a phone with USB debugging on, then run: flutter run"
command -v adb >/dev/null 2>&1 && adb devices || true
