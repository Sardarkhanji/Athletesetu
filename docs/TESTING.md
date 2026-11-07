# AthleteSetu v1.0.0 — Tester Notes

**Build:** 1.0.0 (Android 10+) · signed release · fully offline

## Which file to install

| File | Use for |
|------|---------|
| `AthleteSetu-v1.0.0-arm64-v8a.apk` | Almost every phone from 2019 onward (try this first) |
| `AthleteSetu-v1.0.0-armeabi-v7a.apk` | Only if the arm64 file says "App not installed" (older 32-bit phones) |

Check a download against `SHA256SUMS.txt` if it came over chat or a pen drive.

**Install:** copy the APK to the phone → tap it → allow "Install unknown apps" for your file manager → Install.
Xiaomi/Redmi phones may run a security scan first. Tap "Install anyway" (the app is not from the Play Store).

## What to test

1. **Registration & consent:** register one adult (18+) and one minor. A minor must need a guardian name, relationship and a photo of the signed form before saving.
2. **All 10 tests:** from an athlete's page, run each test.
   - With no setup, switch on **Demo Simulation Mode** (top-right). Every test should complete and show a result sheet.
   - With the real camera (simulation off), check the preview is upright, the level indicator responds when you tilt the phone, and calibration only unlocks within ±2°.
3. **Result sheet:** try both **Confirm & Save** and **Manual Override** (enter your own value and a reason).
4. **Language:** tap **EN | हिं** at the top on several screens. All text should switch.
5. **Reports:** export a PDF for an athlete and check both English and Hindi text read correctly.
6. **Recycle bin:** long-press an athlete → move to recycle bin → restore it from Reports.

## Real-camera setup (optional)

- Height / Vertical Jump: print a **20 cm × 20 cm solid black square** on white paper and tape it to the wall.
- Broad Jump / Medicine Ball: place two such squares on the floor, one at the line and one **3 m** further along.
- Sprint / Shuttle / Endurance: no marker. Drag the dashed line onto the finish or turn mark.
- Use good light. Indoors the camera frame rate drops, and the app warns "FPS below 30".

## Known limitations in v1.0.0

- Pose accuracy on real people has not been validated yet. **Please report how well the skeleton follows the athlete.**
- Timing tests (sprint, shuttle) need ≥30 FPS. Results in dim light or on a hot phone will be less reliable.
- The first camera test after opening the app takes 1–6 s to start while the AI model prepares.
- 2-phone timing needs both phones on the same Wi-Fi or hotspot.
- The app icon is the default placeholder.

## Reporting a problem

Send: phone model, which test, what you did, what happened, and a screenshot.
Results and data never leave the phone, so screenshots are the only way we can see an issue.
