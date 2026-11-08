/// The SAI (Sports Authority of India) 10-battery fitness assessment catalogue.
///
/// Every test declares which engine measures it, what calibration it needs,
/// and how its score is formatted. Engines and UI read from this single source.
library;

enum EngineKind { calibrationOnly, poseFsm, jumpReach, timingGate, assistedOcr }

enum CalibrationKind {
  /// Printed square on the wall (height, vertical jump).
  wallMarker,

  /// Two printed squares on the floor: take-off line + far marker (broad jump, med-ball).
  floorMarkers,

  /// Scale printed on the sit-and-reach box.
  boxScale,

  /// Virtual finish / turn line(s) drawn on the preview (sprint, shuttle, endurance).
  finishLine,

  /// No spatial calibration (weight OCR, sit-ups).
  none,
}

enum SaiTest {
  height(
    id: 'height',
    unit: 'cm',
    decimals: 1,
    higherIsBetter: true,
    engine: EngineKind.jumpReach,
    calibration: CalibrationKind.wallMarker,
    toleranceLabel: '±1 cm',
    attempts: 1,
  ),
  weight(
    id: 'weight',
    unit: 'kg',
    decimals: 1,
    higherIsBetter: true,
    engine: EngineKind.assistedOcr,
    calibration: CalibrationKind.none,
    toleranceLabel: '±0.1 kg',
    attempts: 1,
    needsCamera: false,
  ),
  sitAndReach(
    id: 'sit_and_reach',
    unit: 'cm',
    decimals: 1,
    higherIsBetter: true,
    engine: EngineKind.jumpReach,
    calibration: CalibrationKind.boxScale,
    toleranceLabel: '±2 cm',
    // One recording; the engine itself takes the best of 3 held reaches.
    attempts: 1,
  ),
  verticalJump(
    id: 'vertical_jump',
    unit: 'cm',
    decimals: 1,
    higherIsBetter: true,
    engine: EngineKind.jumpReach,
    calibration: CalibrationKind.wallMarker,
    toleranceLabel: '±2 cm',
    attempts: 3,
  ),
  broadJump(
    id: 'broad_jump',
    unit: 'cm',
    decimals: 0,
    higherIsBetter: true,
    engine: EngineKind.jumpReach,
    calibration: CalibrationKind.floorMarkers,
    toleranceLabel: '±2 cm',
    attempts: 3,
  ),
  medicineBall(
    id: 'medicine_ball',
    unit: 'cm',
    decimals: 0,
    higherIsBetter: true,
    engine: EngineKind.assistedOcr,
    calibration: CalibrationKind.floorMarkers,
    toleranceLabel: '±5 cm',
    attempts: 3,
  ),
  sprint30m(
    id: 'sprint_30m',
    unit: 's',
    decimals: 2,
    higherIsBetter: false,
    engine: EngineKind.timingGate,
    calibration: CalibrationKind.finishLine,
    toleranceLabel: '±0.02 s',
    attempts: 2,
  ),
  shuttleRun(
    id: 'shuttle_run',
    unit: 's',
    decimals: 2,
    higherIsBetter: false,
    engine: EngineKind.timingGate,
    calibration: CalibrationKind.finishLine,
    toleranceLabel: '±0.02 s',
    attempts: 2,
  ),
  sitUps(
    id: 'sit_ups',
    unit: 'reps',
    decimals: 0,
    higherIsBetter: true,
    engine: EngineKind.poseFsm,
    calibration: CalibrationKind.none,
    toleranceLabel: '≥95% rep accuracy',
    attempts: 1,
    durationSec: 30,
  ),
  enduranceRun(
    id: 'endurance_run',
    unit: 's',
    decimals: 1,
    higherIsBetter: false,
    engine: EngineKind.timingGate,
    calibration: CalibrationKind.finishLine,
    toleranceLabel: '±0.1 s',
    attempts: 1,
  );

  const SaiTest({
    required this.id,
    required this.unit,
    required this.decimals,
    required this.higherIsBetter,
    required this.engine,
    required this.calibration,
    required this.toleranceLabel,
    required this.attempts,
    this.durationSec,
    this.needsCamera = true,
  });

  final String id;
  final String unit;
  final int decimals;
  final bool higherIsBetter;
  final EngineKind engine;
  final CalibrationKind calibration;
  final String toleranceLabel;

  /// Maximum attempts; the best valid attempt is kept.
  final int attempts;

  /// Fixed-duration tests (sit-ups).
  final int? durationSec;

  /// Weight uses a still photo of the scale display, not a video stream.
  final bool needsCamera;

  static SaiTest fromId(String id) =>
      SaiTest.values.firstWhere((t) => t.id == id, orElse: () => SaiTest.height);

  bool get isTimed => unit == 's';

  /// Localization keys.
  String get nameKey => 'test_${id}_name';
  String get setupKey => 'test_${id}_setup';

  /// Formats a raw score for display (endurance run shows m:ss.s).
  String format(double? value) {
    if (value == null) return '—';
    if (this == SaiTest.enduranceRun && value >= 60) {
      final m = value ~/ 60;
      final s = value - m * 60;
      return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
    }
    return value.toStringAsFixed(decimals);
  }

  /// Camera orientation for this test. Wide or lying-down scenes record in
  /// landscape (phone turned anticlockwise, top of the phone to the left);
  /// everything else stays portrait. Rolled out one test at a time.
  bool get landscape => this == SaiTest.sitUps;

  /// Test window for an athlete of [ageYears].
  ///
  /// Sit-ups: 30 s under 12, 45 s for 12 and over (Concept Note §5.9; ruling
  /// C30: a 12-year-old follows the 12+ rules, age taken at registration).
  /// Unknown age defaults to 45 s, the KHOJ handbook (Oct 2026) duration.
  int? durationSecForAge(int? ageYears) {
    if (this != SaiTest.sitUps) return durationSec;
    if (ageYears == null) return 45;
    return ageYears < 12 ? 30 : 45;
  }

  /// Picks the better of two scores according to the test's direction.
  bool isBetter(double candidate, double incumbent) =>
      higherIsBetter ? candidate > incumbent : candidate < incumbent;
}
