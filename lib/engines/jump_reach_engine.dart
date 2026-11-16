/// Module C: Height, Vertical Jump, Standing Broad Jump, Sit & Reach.
///
/// * Height (±1 cm): heel baseline → head vertex on the wall-marker plane.
/// * Vertical Jump (±2 cm): spatial reach delta (peak fingertip − standing
///   reach) reconciled with flight-time height h = g·t²/8 → cm + confidence.
/// * Broad Jump (±2 cm): take-off line → rear heel on the settled landing
///   frame, via the floor markers' projective line map.
/// * Sit & Reach (±2 cm): fingertip relative to the box zero mark; a reach
///   counts after a continuous 1.5 s static hold; best of 3.
///
/// Simulation Mode: [JumpReachSimulator] drives a biomechanically plausible
/// side-view athlete (ballistic flight, planted feet, arm swing, sway) through
/// the same calibration and measurement code.
library;

import 'dart:math' as math;

import '../core/domain/sai_test.dart';
import 'calibration_engine.dart';
import 'pose_types.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// The silhouette top is used only if it sits where a head top can be:
/// above the eyes, by at most ~1.3× the eye-to-shoulder distance.
/// Anything else (e.g. a lighting change filling the frame) is ignored.
bool silhouetteTopPlausible(PoseFrame f) {
  final t = f.silhouetteTop;
  if (t == null) return false;
  final eye = f.midpoint(KP.leftEye, KP.rightEye);
  final sh = f.midpoint(KP.leftShoulder, KP.rightShoulder);
  final unit = sh.y - eye.y;
  if (unit <= 0) return false;
  return t.y < eye.y && t.y > eye.y - 1.3 * unit;
}

/// The silhouette bottom is used only if it is at or just below the ankles
/// (within 0.6× the shin length).
bool silhouetteBottomPlausible(PoseFrame f) {
  final b = f.silhouetteBottom;
  if (b == null) return false;
  final s = f[KP.leftAnkle].p.y >= f[KP.rightAnkle].p.y ? 0 : 1;
  final ankle = f.side(s, KP.leftAnkle).p, knee = f.side(s, KP.leftKnee).p;
  final shin = ankle.distanceTo(knee);
  return b.y > ankle.y - 0.1 * shin && b.y < ankle.y + 0.6 * shin;
}

/// Head vertex: silhouette top if plausible, else extrapolated from eyes/shoulders.
Vec2 estimateVertex(PoseFrame f) {
  if (silhouetteTopPlausible(f)) return f.silhouetteTop!;
  final eye = f.midpoint(KP.leftEye, KP.rightEye);
  final sh = f.midpoint(KP.leftShoulder, KP.rightShoulder);
  return Vec2(eye.x, eye.y - 0.545 * (sh.y - eye.y));
}

/// Floor line under the ankles: the ankle joint sits about 0.16 shin lengths
/// (≈ 4% of stature) above the floor.
Vec2 heelFromAnkles(PoseFrame f) {
  final s = f[KP.leftAnkle].p.y >= f[KP.rightAnkle].p.y ? 0 : 1;
  final ankle = f.side(s, KP.leftAnkle).p, knee = f.side(s, KP.leftKnee).p;
  return Vec2(ankle.x, ankle.y + 0.16 * ankle.distanceTo(knee));
}

/// Heel baseline: silhouette bottom if plausible, else below the lower ankle.
Vec2 estimateHeel(PoseFrame f) {
  if (silhouetteBottomPlausible(f)) return f.silhouetteBottom!;
  return heelFromAnkles(f);
}

double _confFromStd(double stdCm, double targetCm) =>
    (100 * math.exp(-math.pow(stdCm / targetCm, 2) / 2)).clamp(0.0, 100.0);

/// Focal length of a phone main camera's video stream, as a fraction of the
/// frame's long side (≈ 68° field of view). Checked on a Moto g45: a 20 cm
/// marker 2.5 m away gives 3.75 px/cm on a 1280 px frame → 0.73.
const double kFocalPerLongSide = 0.75;

// ---------------------------------------------------------------------------
// Height
// ---------------------------------------------------------------------------

class HeightSession implements MeasurementSession {
  HeightSession(this.cal, {this.samplesNeeded = 30, this.lenient = false, bool? liveCamera})
      : liveCamera = liveCamera ?? !cal.simulated;

  final CalibrationResult cal;
  final int samplesNeeded;

  /// Wider stillness tolerances, and a best-effort value when the athlete never
  /// stood fully still, instead of "no reading".
  final bool lenient;

  /// Real camera (not the simulator). The athlete stands in front of the wall,
  /// not in the marker's plane, so the reading is corrected for perspective,
  /// and the floor line comes from the ankles (floor shadows and reflections
  /// make the silhouette's bottom unreliable).
  final bool liveCamera;

  /// How far in front of the wall the measured points are (cm): the top of the
  /// head (mid-skull, head against the wall) and the ankle joint (heels to wall).
  static const headDepthCm = 10.0, ankleDepthCm = 5.0;

  @override
  SaiTest get test => SaiTest.height;

  final _samples = <double>[];
  final _all = <double>[]; // every reading with the athlete in frame (lenient fallback)
  final _recentTorso = <Vec2>[];
  final _scores = <double>[];
  bool _complete = false;
  Vec2? _vertex, _heel;
  bool _usedSilhouette = false;
  double? _cameraDistanceCm;

  double get _stillSpreadCm => lenient ? 3.0 : 1.2;
  double get _stableStdCm => lenient ? 1.5 : 0.6;

  @override
  bool get isComplete => _complete;

  bool _personSeen(PoseFrame f) => lenient
      ? f.scoreOf([
            KP.leftEye, KP.rightEye, KP.leftShoulder, KP.rightShoulder, //
            KP.leftHip, KP.rightHip, KP.leftAnkle, KP.rightAnkle,
          ]) >=
          0.2
      : f.hasPerson;

  /// Height between the two image points, in cm on the wall plane, corrected
  /// (live only) for the points being nearer the camera than the wall.
  double _heightCm(PoseFrame f, Vec2 vertex, Vec2 heel) {
    final top = cal.toPlaneCm(vertex).y, bottom = cal.toPlaneCm(heel).y;
    if (!liveCamera) return top - bottom;
    // Camera-to-wall distance from the marker scale: px/cm = focal px / distance.
    final distCm = kFocalPerLongSide * math.max(f.width, f.height) / cal.pixelsPerCm;
    _cameraDistanceCm = distCm;
    if (distCm < 120) return top - bottom; // too close for the model to hold
    // A point d cm in front of the wall looks (dist / (dist - d)) times further
    // from the camera axis (the image centre) than it is.
    final axisY = cal.toPlaneCm(Vec2(f.width / 2, f.height / 2)).y;
    final topC = axisY + (top - axisY) * (distCm - headDepthCm) / distCm;
    final bottomC = axisY + (bottom - axisY) * (distCm - ankleDepthCm) / distCm;
    return topC - bottomC;
  }

  @override
  EngineSnapshot process(PoseFrame f) {
    if (_complete || !_personSeen(f)) return _snap(const []);
    _recentTorso.add(f.torsoCenter);
    if (_recentTorso.length > 12) _recentTorso.removeAt(0);
    final spreadCm = _recentTorso.length < 12
        ? double.infinity
        : _recentTorso.map((p) => p.distanceTo(_recentTorso.first)).reduce(math.max) / cal.pixelsPerCm;

    _vertex = estimateVertex(f);
    _heel = liveCamera ? heelFromAnkles(f) : estimateHeel(f);
    _usedSilhouette = silhouetteTopPlausible(f);
    final hCm = _heightCm(f, _vertex!, _heel!);
    _all.add(hCm);
    if (_all.length > 90) _all.removeAt(0);

    if (spreadCm < _stillSpreadCm) {
      _samples.add(hCm);
      _scores.add(f.scoreOf([KP.leftEye, KP.rightEye, KP.leftAnkle, KP.rightAnkle]));
      if (_samples.length > samplesNeeded) {
        _samples.removeAt(0);
        _scores.removeAt(0);
      }
      // Only finish once the athlete has stood fully upright and still for the
      // whole window (rejects the last bent-knee frames of walking in).
      if (_samples.length == samplesNeeded && stdDev(_samples) < _stableStdCm) _complete = true;
    } else {
      _samples.clear();
      _scores.clear();
    }
    return _snap([
      HudLine(Vec2(0, _vertex!.y), Vec2(f.width, _vertex!.y), tone: HudTone.pass, label: 'vertex'),
      HudLine(Vec2(0, _heel!.y), Vec2(f.width, _heel!.y), tone: HudTone.pass, label: 'heel'),
      HudLine(Vec2(_vertex!.x, _vertex!.y), Vec2(_vertex!.x, _heel!.y), tone: HudTone.primary, dashed: true),
    ], live: hCm);
  }

  EngineSnapshot _snap(List<HudPrimitive> overlay, {double? live}) => EngineSnapshot(
        phaseKey: _complete
            ? 'phase_finished'
            : (_samples.isEmpty ? 'phase_standing_still' : 'phase_measuring'),
        primary: live == null ? null : (_complete ? median(_samples) : live).toStringAsFixed(1),
        primaryLabelKey: 'units_cm',
        overlay: overlay,
        progress: _samples.length / samplesNeeded,
        complete: _complete,
      );

  @override
  AttemptOutcome finalize() {
    // Strict: at least 5 readings taken while standing still. Lenient: if the
    // athlete never stood still enough, use the last ~3 s of readings instead.
    var values = _samples;
    var steady = true;
    if (_samples.length < 5) {
      steady = false;
      values = lenient && _all.length >= 8 ? _all.sublist(math.max(0, _all.length - 45)) : const [];
    }
    final v = values.isEmpty ? double.nan : median(values);
    // No reading, or one no person can have: leave it to a retake / manual entry.
    if (v.isNaN || v < 50 || v > 250) {
      return AttemptOutcome(
        test: SaiTest.height,
        value: null,
        confidence: 0,
        fouls: const ['phase_standing_still'],
        metadata: {
          'readings': _all.length,
          'steadyReadings': _samples.length,
          if (!v.isNaN) 'rejectedCm': double.parse(v.toStringAsFixed(1)),
          'rules': lenient ? 'lenient' : 'strict',
        },
      );
    }
    final sd = stdDev(values);
    final kp = _scores.isEmpty ? 0.5 : mean(_scores);
    var conf = _confFromStd(sd, lenient ? 2.0 : 1.0) * 0.55 +
        cal.confidence * 0.30 +
        (kp * 100).clamp(0, 100) * 0.10 +
        (_usedSilhouette ? 5 : 0);
    if (!steady) conf *= 0.6;
    return AttemptOutcome(
      test: test,
      value: v,
      confidence: conf.clamp(0, 99),
      metadata: {
        'samples': values.length,
        'stdCm': double.parse(sd.toStringAsFixed(2)),
        'method': _usedSilhouette ? 'silhouette' : 'keypoint_extrapolation',
        'steady': steady,
        'rules': lenient ? 'lenient' : 'strict',
        'perspectiveCorrected': liveCamera && (_cameraDistanceCm ?? 0) >= 120,
        if (_cameraDistanceCm != null) 'cameraDistanceCm': _cameraDistanceCm!.round(),
        'calibration': cal.toJson(),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Vertical jump
// ---------------------------------------------------------------------------

enum _VjPhase { standingReach, ready, flight, landed, done }

class VerticalJumpSession implements MeasurementSession {
  VerticalJumpSession(this.cal);

  final CalibrationResult cal;

  @override
  SaiTest get test => SaiTest.verticalJump;

  _VjPhase _phase = _VjPhase.standingReach;
  final _reachWindow = <double>[];
  final _ankleWindow = <double>[];
  double? _standingReachCm, _baselineAnkleY, _shinPx;
  PoseFrame? _prev;
  double? _takeoffMs, _landingMs, _peakFingerY;
  double _peakReachCm = -1e9;
  final _flightScores = <double>[];
  final _fouls = <String>[];
  double _lastT = 0;
  final _peakPath = <Vec2>[];

  @override
  bool get isComplete => _phase == _VjPhase.done;

  double _ankleY(PoseFrame f) => math.max(f[KP.leftAnkle].p.y, f[KP.rightAnkle].p.y);

  /// Higher hand's fingertip (smaller y).
  Vec2 _finger(PoseFrame f) {
    final l = f.fingertip(0), r = f.fingertip(1);
    return l.y <= r.y ? l : r;
  }

  double get _thresholdPx => _shinPx! * (kTiptoeShinRatio + 0.04) + cal.pixelsPerCm * 1.0;

  @override
  EngineSnapshot process(PoseFrame f) {
    _lastT = f.tMs;
    if (!f.hasPerson || _phase == _VjPhase.done) {
      _prev = f;
      return _snap(f);
    }
    final finger = _finger(f);
    final ankleY = _ankleY(f);

    switch (_phase) {
      case _VjPhase.standingReach:
        final head = estimateVertex(f);
        if (finger.y < head.y) {
          _reachWindow.add(cal.toPlaneCm(finger).y);
          _ankleWindow.add(ankleY);
          if (_reachWindow.length > 24) {
            _reachWindow.removeAt(0);
            _ankleWindow.removeAt(0);
          }
          if (_reachWindow.length == 24 && stdDev(_reachWindow) < 0.8) {
            _standingReachCm = median(_reachWindow);
            _baselineAnkleY = median(_ankleWindow);
            final s = f.nearSide;
            _shinPx = f.side(s, KP.leftKnee).p.distanceTo(f.side(s, KP.leftAnkle).p);
            _phase = _VjPhase.ready;
          }
        } else {
          _reachWindow.clear();
          _ankleWindow.clear();
        }
      case _VjPhase.ready:
        final lift = _baselineAnkleY! - math.max(f[KP.leftAnkle].p.y, f[KP.rightAnkle].p.y);
        if (lift > _thresholdPx && _prev != null) {
          // Interpolate the threshold crossing, then back-correct to toe-off
          // using the ankle's vertical speed (ankle is above the floor on the toes).
          final prevLift = _baselineAnkleY! - _ankleY(_prev!);
          final frac = ((_thresholdPx - prevLift) / math.max(lift - prevLift, 1e-6)).clamp(0.0, 1.0);
          final tCross = _prev!.tMs + (f.tMs - _prev!.tMs) * frac;
          final speed = (lift - prevLift) / math.max(f.tMs - _prev!.tMs, 1e-6); // px/ms
          final delta = _thresholdPx - _shinPx! * kTiptoeShinRatio;
          _takeoffMs = tCross - (speed > 0 ? delta / speed : 0);
          _phase = _VjPhase.flight;
        }
      case _VjPhase.flight:
        _flightScores.add(f.meanScore);
        final reach = cal.toPlaneCm(finger).y;
        if (reach > _peakReachCm) {
          _peakReachCm = reach;
          _peakFingerY = finger.y;
        }
        _peakPath.add(finger);
        final lift = _baselineAnkleY! - _ankleY(f);
        if (lift <= _thresholdPx && _prev != null) {
          final prevLift = _baselineAnkleY! - _ankleY(_prev!);
          final frac = ((prevLift - _thresholdPx) / math.max(prevLift - lift, 1e-6)).clamp(0.0, 1.0);
          final tCross = _prev!.tMs + (f.tMs - _prev!.tMs) * frac;
          final speed = (prevLift - lift) / math.max(f.tMs - _prev!.tMs, 1e-6);
          final delta = _thresholdPx - _shinPx! * kTiptoeShinRatio;
          final landing = tCross + (speed > 0 ? delta / speed : 0);
          if (landing - _takeoffMs! < 120) {
            _phase = _VjPhase.ready; // noise blip, not a jump
            _peakReachCm = -1e9;
            _peakPath.clear();
          } else {
            _landingMs = landing;
            _phase = _VjPhase.landed;
          }
        }
      case _VjPhase.landed:
        if (f.tMs - _landingMs! > 500) _phase = _VjPhase.done;
      case _VjPhase.done:
        break;
    }
    _prev = f;
    return _snap(f);
  }

  EngineSnapshot _snap(PoseFrame f) {
    final overlay = <HudPrimitive>[];
    if (_standingReachCm != null && _reachWindow.isNotEmpty) {
      final y = _reachWindow.isEmpty ? 0.0 : _fingerYForCm(_standingReachCm!, f);
      overlay.add(HudLine(Vec2(0, y), Vec2(f.width, y), tone: HudTone.primary, dashed: true, label: 'reach'));
    }
    if (_peakFingerY != null) {
      overlay.add(HudLine(Vec2(0, _peakFingerY!), Vec2(f.width, _peakFingerY!), tone: HudTone.pass, label: 'peak'));
    }
    if (_baselineAnkleY != null) {
      overlay.add(HudLine(Vec2(0, _baselineAnkleY!), Vec2(f.width, _baselineAnkleY!), tone: HudTone.neutral));
    }
    if (_peakPath.length > 1) overlay.add(HudPath(List.of(_peakPath), tone: HudTone.warning));
    final live = _peakReachCm > -1e8 && _standingReachCm != null ? _peakReachCm - _standingReachCm! : null;
    return EngineSnapshot(
      phaseKey: switch (_phase) {
        _VjPhase.standingReach => 'phase_standing_reach',
        _VjPhase.ready => 'phase_crouch',
        _VjPhase.flight => 'phase_flight',
        _VjPhase.landed => 'phase_landed',
        _VjPhase.done => 'phase_finished',
      },
      primary: live?.toStringAsFixed(1),
      primaryLabelKey: 'units_cm',
      secondary: _takeoffMs != null && _landingMs != null
          ? 't=${(_landingMs! - _takeoffMs!).round()} ms'
          : null,
      overlay: overlay,
      fouls: List.unmodifiable(_fouls),
      complete: isComplete,
    );
  }

  double _fingerYForCm(double cm, PoseFrame f) {
    // Inverse map along the vertical through the image centre.
    final inv = cal.planeHomography?.inverse();
    if (inv == null) return f.height / 2;
    final centreCm = cal.toPlaneCm(Vec2(f.width / 2, f.height / 2));
    return inv.map(Vec2(centreCm.x, cm)).y;
  }

  @override
  AttemptOutcome finalize() {
    if (_standingReachCm == null || _takeoffMs == null || _landingMs == null) {
      return AttemptOutcome(
        test: test,
        value: null,
        confidence: 0,
        fouls: [if (_standingReachCm != null) 'foul_no_flight' else 'phase_standing_reach'],
        metadata: {'lastT': _lastT},
      );
    }
    final tFlight = (_landingMs! - _takeoffMs!) / 1000;
    final flightCm = kGravity * tFlight * tFlight / 8 * 100;
    // Toe extension at take-off: flight height + toe lift = reach-equivalent (Sargent) height.
    final toeLiftCm = _shinPx! * kTiptoeShinRatio / cal.pixelsPerCm;
    final flightReachEq = flightCm + toeLiftCm;
    final spatialCm = _peakReachCm - _standingReachCm!;

    final fps = cal.quality?.fps ?? 30;
    // ±½-frame timing quantisation per event → σ_t; dh/dt = g·t/4.
    final sigmaT = (1 / fps) / math.sqrt(6);
    final sigmaFlight = kGravity * tFlight / 4 * sigmaT * 100 + 0.8;
    final sigmaSpatial = 1.2 + 2.0 / cal.pixelsPerCm;
    final wF = 1 / (sigmaFlight * sigmaFlight), wS = 1 / (sigmaSpatial * sigmaSpatial);
    final reconciled = (flightReachEq * wF + spatialCm * wS) / (wF + wS);
    final disagreement = (flightReachEq - spatialCm).abs();
    final agreement = math.exp(-math.pow(disagreement, 2) /
        (2 * (sigmaFlight * sigmaFlight + sigmaSpatial * sigmaSpatial + 1)));
    final kp = _flightScores.isEmpty ? 0.6 : mean(_flightScores);
    final conf = (100 * (0.55 * agreement + 0.25 * kp.clamp(0.0, 1.0) + 0.20 * cal.confidence / 100))
        .clamp(5.0, 99.0);

    return AttemptOutcome(
      test: test,
      value: reconciled,
      confidence: conf,
      metadata: {
        'spatialDeltaCm': double.parse(spatialCm.toStringAsFixed(1)),
        'flightTimeMs': (tFlight * 1000).round(),
        'flightHeightCm': double.parse(flightCm.toStringAsFixed(1)),
        'flightReachEquivalentCm': double.parse(flightReachEq.toStringAsFixed(1)),
        'standingReachCm': double.parse(_standingReachCm!.toStringAsFixed(1)),
        'disagreementCm': double.parse(disagreement.toStringAsFixed(1)),
        'calibration': cal.toJson(),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Standing broad jump
// ---------------------------------------------------------------------------

enum _BjPhase { standing, flight, landed, settling, done }

class BroadJumpSession implements MeasurementSession {
  BroadJumpSession(this.cal, {this.athleteHeightCm});

  final CalibrationResult cal;
  final double? athleteHeightCm;

  @override
  SaiTest get test => SaiTest.broadJump;

  LineProjectiveMap get _line => cal.lineMap!;
  _BjPhase _phase = _BjPhase.standing;
  final _standOffsets = <double>[];
  double? _offset; // ankle height above the floor line when standing (px)
  double? _takeoffMs, _landingMs;
  final _settleL = <Vec2>[], _settleR = <Vec2>[];
  double? _distanceCm;
  double _settleSpreadCm = 0;
  double? _statureEstCm;
  final _scores = <double>[];
  Vec2? _rearHeelPx;
  final _fouls = <String>[];

  @override
  bool get isComplete => _phase == _BjPhase.done;

  double _lift(Vec2 ankle) => _line.yAtX(ankle.x) - ankle.y;

  /// Local px per cm along the line near an image x.
  double _localPpc(double x) {
    final w = _line.worldAt(Vec2(x, _line.yAtX(x)));
    return _line.imageAt(w + 10).distanceTo(_line.imageAt(w)) / 10;
  }

  double get _heelOffsetCm => kHeelBehindAnkleRatio * (athleteHeightCm ?? _statureEstCm ?? 150);

  @override
  EngineSnapshot process(PoseFrame f) {
    if (!f.hasPerson || isComplete) return _snap(f);
    final la = f[KP.leftAnkle].p, ra = f[KP.rightAnkle].p;
    final lift = math.min(_lift(la), _lift(ra));
    final ppc = _localPpc((la.x + ra.x) / 2);

    switch (_phase) {
      case _BjPhase.standing:
        _standOffsets.add(lift);
        if (_standOffsets.length > 20) _standOffsets.removeAt(0);
        if (_standOffsets.length >= 10) {
          _offset = median(_standOffsets);
          _statureEstCm ??= (estimateHeel(f).y - estimateVertex(f).y) / ppc;
        }
        // 7 cm clears the toe-rise just before take-off.
        if (_offset != null && lift > _offset! + 7 * ppc) {
          _takeoffMs = f.tMs;
          _phase = _BjPhase.flight;
        }
      case _BjPhase.flight:
        _scores.add(f.meanScore);
        if (lift < _offset! + 1.5 * ppc) {
          _landingMs = f.tMs;
          _phase = _BjPhase.landed;
        }
      case _BjPhase.landed:
      case _BjPhase.settling:
        _phase = _BjPhase.settling;
        _settleL.add(la);
        _settleR.add(ra);
        if (_settleL.length > 20) {
          _settleL.removeAt(0);
          _settleR.removeAt(0);
        }
        if (_settleL.length == 20) {
          double sd(List<Vec2> pts) => math.sqrt(math.pow(stdDev(pts.map((p) => p.x).toList()), 2) +
              math.pow(stdDev(pts.map((p) => p.y).toList()), 2));
          final spread = math.max(sd(_settleL), sd(_settleR));
          if (spread / ppc < 1.0) {
            _settleSpreadCm = spread / ppc;
            _measure();
            _phase = _BjPhase.done;
          }
        }
      case _BjPhase.done:
        break;
    }
    return _snap(f);
  }

  void _measure() {
    double xOf(List<Vec2> pts) {
      final p = Vec2(median(pts.map((e) => e.x).toList()), median(pts.map((e) => e.y).toList()));
      return _line.worldAt(Vec2(p.x, _line.yAtX(p.x)));
    }

    final lx = xOf(_settleL), rx = xOf(_settleR);
    final rearAnkle = math.min(lx, rx);
    _distanceCm = rearAnkle - _heelOffsetCm; // take-off line is X = 0
    _rearHeelPx = _line.imageAt(_distanceCm!);
  }

  EngineSnapshot _snap(PoseFrame f) {
    final take = _line.imageAt(0);
    final overlay = <HudPrimitive>[
      HudLine(take + const Vec2(0, -40), take + const Vec2(0, 40), tone: HudTone.warning, width: 3, label: '0'),
      HudLine(_line.imageAt(-50), _line.imageAt(350), tone: HudTone.neutral, dashed: true),
      if (_rearHeelPx != null) ...[
        HudPoint(_rearHeelPx!, tone: HudTone.pass, radius: 8),
        HudLine(take, _rearHeelPx!, tone: HudTone.pass, width: 4, label: '${_distanceCm!.round()} cm'),
      ],
    ];
    return EngineSnapshot(
      phaseKey: switch (_phase) {
        _BjPhase.standing => 'phase_standing_still',
        _BjPhase.flight => 'phase_flight',
        _BjPhase.landed => 'phase_landed',
        _BjPhase.settling => 'phase_settling',
        _BjPhase.done => 'phase_finished',
      },
      primary: _distanceCm?.toStringAsFixed(0),
      primaryLabelKey: 'units_cm',
      overlay: overlay,
      fouls: List.unmodifiable(_fouls),
      complete: isComplete,
    );
  }

  @override
  AttemptOutcome finalize() {
    if (_distanceCm == null) {
      return AttemptOutcome(
        test: test,
        value: null,
        confidence: 0,
        fouls: [if (_takeoffMs == null) 'foul_no_flight' else 'phase_settling'],
      );
    }
    final kp = _scores.isEmpty ? 0.7 : mean(_scores);
    final conf = (cal.confidence * 0.4 +
            _confFromStd(_settleSpreadCm, 1.5) * 0.35 +
            kp.clamp(0.0, 1.0) * 100 * 0.25)
        .clamp(5.0, 99.0);
    return AttemptOutcome(
      test: test,
      value: _distanceCm,
      confidence: conf,
      metadata: {
        'flightMs': _landingMs != null && _takeoffMs != null ? (_landingMs! - _takeoffMs!).round() : null,
        'heelOffsetCm': double.parse(_heelOffsetCm.toStringAsFixed(1)),
        'settleSpreadCm': double.parse(_settleSpreadCm.toStringAsFixed(2)),
        'calibration': cal.toJson(),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Sit & reach
// ---------------------------------------------------------------------------

class ReachAttempt {
  ReachAttempt(this.startMs);
  final double startMs;
  double maxReachCm = -1e9;
  double? heldReachCm;
  double heldMs = 0;
  final Set<String> fouls = {};
  bool get valid => heldReachCm != null && fouls.isEmpty;

  Map<String, Object?> toJson() => {
        'reachCm': heldReachCm == null ? null : double.parse(heldReachCm!.toStringAsFixed(1)),
        'maxReachCm': double.parse(maxReachCm.toStringAsFixed(1)),
        'heldMs': heldMs.round(),
        'valid': valid,
        'fouls': fouls.toList(),
      };
}

class SitReachSession implements MeasurementSession {
  SitReachSession(this.cal,
      {this.maxAttempts = 3, this.holdMs = 1500, this.reachOffsetCm = 0, this.lenient = false});

  final CalibrationResult cal;
  final int maxAttempts;
  final double holdMs;

  /// Added to the box reading (some protocols put the zero mark 15/23 cm from the feet).
  final double reachOffsetCm;

  /// KHOJ handbook: the tape's 23 cm mark is on the heel line (0 is 23 cm behind it).
  static const heelLineCm = 23.0;

  /// Lenient rule set: a wider hold band, a knee-bend foul only when the knee
  /// is clearly bent for most of the reach, and a best-effort value (the
  /// furthest reach) when no reach was held long enough.
  final bool lenient;

  @override
  SaiTest get test => SaiTest.sitAndReach;

  final attempts = <ReachAttempt>[];
  ReachAttempt? _current;
  double? _restCm;
  final _window = <(double, double)>[]; // (t, smoothed reachCm)
  double? _reachEma;

  /// Hold = smoothed fingertip stays within this band for [holdMs].
  static const holdBandCm = 1.5;
  double get _holdBandCm => lenient ? 4.0 : holdBandCm;

  // Lenient knee check: frames of the current attempt, and how many had a bent knee.
  int _attemptFrames = 0, _kneeBentFrames = 0;
  double? _maxSeenCm;
  final _scores = <double>[];
  final _fouls = <String>[];
  Vec2? _finger;
  int _facing = 1;

  @override
  bool get isComplete => attempts.length >= maxAttempts;

  double _reachCm(PoseFrame f) {
    final l = f.fingertip(0), r = f.fingertip(1);
    // Furthest hand in the reaching direction.
    final ahead = (_facing > 0) == (l.x >= r.x) ? l : r;
    _finger = ahead;
    final x = cal.toPlaneCm(ahead).x;
    return _facing * x + reachOffsetCm;
  }

  @override
  EngineSnapshot process(PoseFrame f) {
    final seen = lenient
        ? f.scoreOf([KP.leftShoulder, KP.rightShoulder, KP.leftHip, KP.rightHip, KP.leftWrist, KP.rightWrist]) >= 0.2
        : f.hasPerson;
    if (!seen || isComplete) return _snap(f, null);
    // Facing: the athlete reaches from hips towards feet.
    final hip = f.midpoint(KP.leftHip, KP.rightHip), ankle = f.midpoint(KP.leftAnkle, KP.rightAnkle);
    _facing = ankle.x >= hip.x ? 1 : -1;
    final raw = _reachCm(f);
    _reachEma = _reachEma == null ? raw : _reachEma! + 0.35 * (raw - _reachEma!);
    final reach = _reachEma!;
    _scores.add(f.meanScore);
    final s = f.nearSide;
    final knee = angleDeg(f.side(s, KP.leftHip).p, f.side(s, KP.leftKnee).p, f.side(s, KP.leftAnkle).p);

    _maxSeenCm = _maxSeenCm == null ? reach : math.max(_maxSeenCm!, reach);
    _restCm ??= reach;
    if (_current == null) {
      _restCm = math.min(_restCm!, reach);
      if (reach > _restCm! + 6) {
        _current = ReachAttempt(f.tMs);
        _window.clear();
        _attemptFrames = 0;
        _kneeBentFrames = 0;
      }
    }
    final cur = _current;
    if (cur != null) {
      cur.maxReachCm = math.max(cur.maxReachCm, reach);
      _attemptFrames++;
      if (lenient) {
        if (knee < 140) _kneeBentFrames++;
      } else if (knee < 160) {
        cur.fouls.add('foul_knee_bent');
      }
      _window.add((f.tMs, reach));
      while (_window.isNotEmpty && f.tMs - _window.first.$1 > holdMs) {
        _window.removeAt(0);
      }
      final span = _window.last.$1 - _window.first.$1;
      final values = _window.map((e) => e.$2).toList();
      final range = values.reduce(math.max) - values.reduce(math.min);
      final stillMs = _stillSpanMs();
      cur.heldMs = math.max(cur.heldMs, stillMs);
      if (cur.heldReachCm == null && span >= holdMs * 0.97 && range < _holdBandCm && reach > cur.maxReachCm - 2) {
        cur.heldReachCm = median(values);
      }
      // Retraction ends the attempt.
      if (reach < cur.maxReachCm - 8) {
        if (cur.heldReachCm == null) cur.fouls.add('foul_hold_short');
        _applyLenientKneeFoul(cur);
        attempts.add(cur);
        _fouls.addAll(cur.fouls);
        _current = null;
        _restCm = reach;
      }
    }
    return _snap(f, reach);
  }

  /// Lenient: knee bent (< 140°) on more than half of the attempt's frames.
  void _applyLenientKneeFoul(ReachAttempt a) {
    if (lenient && _attemptFrames >= 4 && _kneeBentFrames > _attemptFrames * 0.5) a.fouls.add('foul_knee_bent');
  }

  /// How long (ms) the most recent samples have stayed within the hold band.
  double _stillSpanMs() {
    if (_window.isEmpty) return 0;
    var lo = _window.last.$2, hi = lo;
    var start = _window.last.$1;
    for (var i = _window.length - 1; i >= 0; i--) {
      final v = _window[i].$2;
      lo = math.min(lo, v);
      hi = math.max(hi, v);
      if (hi - lo >= _holdBandCm) break;
      start = _window[i].$1;
    }
    return _window.last.$1 - start;
  }

  EngineSnapshot _snap(PoseFrame f, double? live) {
    final cur = _current;
    final zero = cal.planeHomography?.inverse().map(const Vec2(0, 10));
    final overlay = <HudPrimitive>[
      if (zero != null) HudLine(zero + const Vec2(0, -60), zero + const Vec2(0, 30), tone: HudTone.warning, width: 3, label: '0'),
      if (_finger != null) HudPoint(_finger!, tone: cur?.heldReachCm != null ? HudTone.pass : HudTone.primary, radius: 8),
    ];
    final holdS = cur == null ? 0.0 : (cur.heldMs / 1000).clamp(0.0, holdMs / 1000);
    final best = _best();
    return EngineSnapshot(
      phaseKey: isComplete
          ? 'phase_finished'
          : (cur == null ? 'phase_idle' : (holdS > 0.2 ? 'phase_holding' : 'phase_reaching')),
      phaseParams: {'s': holdS.toStringAsFixed(1)},
      primary: (cur != null ? live : best)?.toStringAsFixed(1),
      primaryLabelKey: 'units_cm',
      secondary: '${attempts.length}/$maxAttempts',
      overlay: overlay,
      fouls: List.unmodifiable(_fouls),
      complete: isComplete,
      progress: cur == null ? null : holdS / (holdMs / 1000),
    );
  }

  /// Best reach that met every rule (held, no foul).
  double? _bestValid() {
    final valid = attempts.where((a) => a.valid).map((a) => a.heldReachCm!);
    return valid.isEmpty ? null : valid.reduce(math.max);
  }

  /// Strict: the best valid reach. Lenient: if there is none, fall back to the
  /// best held reach, then the furthest reach of any attempt, then the furthest
  /// reach seen at all, so an attempt always yields a value to review.
  double? _best() {
    final valid = _bestValid();
    if (valid != null || !lenient) return valid;
    final held = attempts.where((a) => a.heldReachCm != null).map((a) => a.heldReachCm!);
    if (held.isNotEmpty) return held.reduce(math.max);
    if (attempts.isNotEmpty) return attempts.map((a) => a.maxReachCm).reduce(math.max);
    return _maxSeenCm;
  }

  @override
  AttemptOutcome finalize() {
    if (_current != null) {
      if (_current!.heldReachCm == null) _current!.fouls.add('foul_hold_short');
      _applyLenientKneeFoul(_current!);
      attempts.add(_current!);
      _current = null;
    }
    final best = _best();
    final metRules = _bestValid() != null;
    final kp = _scores.isEmpty ? 0.6 : mean(_scores);
    final validCount = attempts.where((a) => a.valid).length;
    // A best-effort value (no reach met every rule) is capped at 55%.
    final conf = best == null
        ? 0.0
        : metRules
            ? (cal.confidence * 0.45 + kp.clamp(0.0, 1.0) * 100 * 0.35 + (validCount >= 2 ? 20 : 10)).clamp(5.0, 99.0)
            : (cal.confidence * 0.30 + kp.clamp(0.0, 1.0) * 100 * 0.20).clamp(5.0, 55.0);
    return AttemptOutcome(
      test: test,
      value: best,
      confidence: conf,
      fouls: {for (final a in attempts) ...a.fouls}.toList(),
      metadata: {
        'attempts': attempts.map((a) => a.toJson()).toList(),
        'holdMs': holdMs,
        'rules': lenient ? 'lenient' : 'strict',
        'metAllRules': metRules,
        'calibration': cal.toJson(),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Simulation
// ---------------------------------------------------------------------------

/// Joint-angle keyframe: [thigh, shin, torso, upperArm, forearm, farUpper, farFore, tiptoe].
class _Key {
  const _Key(this.t, this.v);
  final double t;
  final List<double> v;
}

List<double> _interp(List<_Key> keys, double t) {
  if (t <= keys.first.t) return keys.first.v;
  for (var i = 1; i < keys.length; i++) {
    if (t <= keys[i].t) {
      final a = keys[i - 1], b = keys[i];
      final u = smoothstep(a.t, b.t, t);
      return [for (var k = 0; k < a.v.length; k++) lerpD(a.v[k], b.v[k], u)];
    }
  }
  return keys.last.v;
}

class JumpReachSimulator extends FrameSimulator {
  JumpReachSimulator(this.test, {int seed = 3, double? statureM})
      : _noise = SimNoise(seed),
        statureM = statureM ?? 1.30 + SimNoise(seed + 1).uniform(0, 0.5) {
    _rig = SideRig(this.statureM);
    _setup();
  }

  @override
  final SaiTest test;
  final double statureM;
  final SimNoise _noise;
  late final SideRig _rig;
  late final SimCamera cam;
  late List<_Key> _keys;
  late double _duration;
  final Map<String, Object?> _truth = {};

  // Vertical / broad jump flight parameters.
  double _tTakeoff = 0, _tFlight = 0, _v0y = 0, _vx = 0;
  (double, double) _hip0 = (0, 0);
  double _ankleX0 = 0, _ankleXLand = 0;

  // Sit & reach.
  double _footLineX = 0;
  final _reachPlan = <(double start, double hold, double torso)>[];

  CalibrationKind get calibrationKind => test.calibration;

  @override
  double get width => cam.width;
  @override
  double get height => cam.height;
  @override
  double get fps => test == SaiTest.verticalJump || test == SaiTest.broadJump ? 60 : 30;
  @override
  double get durationMs => _duration * 1000;

  /// Where the simulated printed markers sit (consumed by [CalibrationSimulator]).
  ({double wallX, double wallBaseY}) get markerPlacement => switch (test) {
        SaiTest.sitAndReach => (wallX: _footLineX, wallBaseY: 0.08),
        _ => (wallX: -0.65, wallBaseY: 1.0),
      };

  static const _pi = math.pi;

  void _setup() {
    final h = statureM;
    switch (test) {
      case SaiTest.height:
        cam = SimCamera(width: 720, height: 1280, focalPx: 1250, position: (0, 1.0, -2.6));
        _keys = const [
          _Key(0, [0.25, -0.1, _pi, 0.3, 0.4, -0.3, -0.2, 0]),
          _Key(0.5, [-0.25, -0.35, _pi, -0.3, -0.2, 0.3, 0.4, 0]),
          _Key(1.0, [0, 0, _pi, 0.05, 0.05, -0.05, -0.05, 0]),
          _Key(9, [0, 0, _pi, 0.05, 0.05, -0.05, -0.05, 0]),
        ];
        _duration = 5.0;
        _truth['trueHeightCm'] = h * 100;
      case SaiTest.verticalJump:
        cam = SimCamera(width: 720, height: 1280, focalPx: 1300, position: (0, 1.15, -3.3));
        final jumpH = _noise.uniform(0.24, 0.48);
        _tFlight = math.sqrt(8 * jumpH / kGravity);
        _tTakeoff = 2.25;
        _v0y = kGravity * _tFlight / 2;
        _keys = [
          const _Key(0, [0, 0, _pi, _pi, _pi, 0.1, 0.2, 0]),
          const _Key(1.7, [0, 0, _pi, _pi, _pi, 0.1, 0.2, 0]),
          const _Key(2.0, [1.05, -0.6, _pi - 0.5, -0.8, -0.6, -0.8, -0.6, 0]),
          _Key(_tTakeoff, const [0, 0, _pi, _pi, _pi, _pi - 0.3, _pi - 0.2, 1]),
          _Key(_tTakeoff + _tFlight, const [0.05, -0.05, _pi, _pi, _pi, _pi - 0.3, _pi - 0.2, 1]),
          _Key(_tTakeoff + _tFlight + 0.25, const [0.9, -0.5, _pi - 0.35, 0.6, 0.9, 0.6, 0.9, 0]),
          _Key(_tTakeoff + _tFlight + 0.8, const [0, 0, _pi, 0.1, 0.2, -0.1, 0, 0]),
        ];
        _ankleX0 = 0;
        _duration = _tTakeoff + _tFlight + 1.8;
        _truth['trueFlightHeightCm'] = jumpH * 100;
        _truth['trueReachDeltaCm'] = (jumpH + _rig.shinLen * kTiptoeShinRatio) * 100;
      case SaiTest.broadJump:
        cam = SimCamera(width: 720, height: 1280, focalPx: 860, position: (1.1, 1.35, -4.6), pitchDeg: 11);
        final dist = _noise.uniform(1.25, 2.05);
        _tTakeoff = 2.0;
        _tFlight = _noise.uniform(0.42, 0.52);
        _ankleX0 = -0.07;
        _keys = [
          const _Key(0, [0, 0, _pi, 0.1, 0.2, -0.1, 0, 0]),
          const _Key(1.2, [0, 0, _pi, 0.1, 0.2, -0.1, 0, 0]),
          const _Key(1.75, [1.15, -0.6, _pi - 0.75, -1.0, -0.8, -1.0, -0.8, 0]),
          _Key(_tTakeoff, const [-0.35, -0.35, _pi - 0.6, _pi - 0.6, _pi - 0.5, _pi - 0.6, _pi - 0.5, 1]),
          _Key(_tTakeoff + _tFlight, const [1.3, 0.25, _pi - 0.45, 1.4, 1.5, 1.4, 1.5, 0]),
          _Key(_tTakeoff + _tFlight + 0.45, const [1.1, -0.5, _pi - 0.6, 0.9, 1.1, 0.9, 1.1, 0]),
          _Key(_tTakeoff + _tFlight + 3, const [1.1, -0.5, _pi - 0.6, 0.9, 1.1, 0.9, 1.1, 0]),
        ];
        // Rear (far-side) ankle lands so its heel is exactly `dist` past the line.
        final farOffset = 0.012 * h;
        _ankleXLand = dist + _rig.heelBehindAnkle + farOffset;
        final take = _interp(_keys, _tTakeoff);
        _hip0 = _plantedHip(_ankleX0, _rig.ankleHeight + _rig.shinLen * kTiptoeShinRatio, take[0], take[1]);
        final land = _interp(_keys, _tTakeoff + _tFlight);
        final hipLand = _plantedHip(_ankleXLand, _rig.ankleHeight, land[0], land[1]);
        _vx = (hipLand.$1 - _hip0.$1) / _tFlight;
        _v0y = (hipLand.$2 - _hip0.$2 + kGravity * _tFlight * _tFlight / 2) / _tFlight;
        _duration = _tTakeoff + _tFlight + 2.6;
        _truth['trueDistanceCm'] = dist * 100;
      case SaiTest.sitAndReach:
        cam = SimCamera(width: 720, height: 1280, focalPx: 980, position: (0.5, 0.45, -1.9));
        _footLineX = _rig.thighLen + _rig.shinLen + 0.025 * h;
        var t = 1.0;
        final shortHold = _noise.nextInt(3); // one attempt may be released early
        final plannedShort = _noise.chance(0.45);
        for (var i = 0; i < 3; i++) {
          final hold = (plannedShort && i == shortHold) ? 0.9 : _noise.uniform(1.9, 2.3);
          final torso = _noise.uniform(2.2, 2.6);
          _reachPlan.add((t, hold, torso));
          t += 1.0 + hold + 0.8 + 0.9;
        }
        _duration = t + 0.5;
        // Truth: fingertip (wrist + 0.75·forearm) beyond the foot line during each hold.
        final truths = <double?>[];
        for (final (_, hold, torso) in _reachPlan) {
          final j = _rig.joints(_sitPose(torso, 1));
          final w = j[KP.leftWrist]!, e = j[KP.leftElbow]!;
          final tip = w.$1 + (w.$1 - e.$1) * 0.75;
          truths.add(hold >= 1.5 ? (tip - _footLineX) * 100 : null);
        }
        _truth['attemptReachCm'] = truths.map((v) => v == null ? null : double.parse(v.toStringAsFixed(1))).toList();
        final valid = truths.whereType<double>();
        _truth['trueBestReachCm'] = valid.isEmpty ? null : valid.reduce(math.max);
      default:
        throw ArgumentError('JumpReachSimulator does not simulate ${test.id}');
    }
  }

  (double, double) _plantedHip(double ankleX, double ankleY, double thigh, double shin) {
    final sx = math.sin(shin) * _rig.shinLen, sy = -math.cos(shin) * _rig.shinLen;
    final tx = math.sin(thigh) * _rig.thighLen, ty = -math.cos(thigh) * _rig.thighLen;
    return (ankleX - sx - tx, ankleY - sy - ty);
  }

  RigPose _sitPose(double torso, double reach) => RigPose(
        hipX: 0,
        hipY: 0.09,
        facing: 1,
        torso: lerpD(_pi - 0.1, torso, reach),
        thighL: _pi / 2,
        shinL: _pi / 2,
        thighR: _pi / 2,
        shinR: _pi / 2,
        upperArmL: lerpD(_pi / 2 + 0.25, _pi / 2 - 0.05, reach),
        forearmL: lerpD(_pi / 2 + 0.15, _pi / 2 - 0.08, reach),
        upperArmR: lerpD(_pi / 2 + 0.25, _pi / 2 - 0.05, reach),
        forearmR: lerpD(_pi / 2 + 0.15, _pi / 2 - 0.08, reach),
      );

  @override
  PoseFrame frameAt(double tMs, int index) {
    final t = tMs / 1000;
    late RigPose pose;
    switch (test) {
      case SaiTest.height:
        final v = _interp(_keys, t);
        final walkX = lerpD(-0.8, 0, smoothstep(0, 1.0, t));
        final sway = t > 1.2 ? _noise.gauss(0.0006) : 0.0;
        final hip = _plantedHip(walkX, _rig.ankleHeight, v[0], v[1]);
        pose = RigPose(
          hipX: hip.$1 + sway,
          hipY: hip.$2,
          torso: v[2],
          upperArmL: v[3],
          forearmL: v[4],
          upperArmR: v[5],
          forearmR: v[6],
          thighL: v[0],
          shinL: v[1],
          thighR: -v[0],
          shinR: v[1],
        );
      case SaiTest.verticalJump:
      case SaiTest.broadJump:
        final v = _interp(_keys, t);
        final tiptoe = v[7] * _rig.shinLen * kTiptoeShinRatio;
        (double, double) hip;
        if (t >= _tTakeoff && t <= _tTakeoff + _tFlight) {
          final tau = t - _tTakeoff;
          final h0 = test == SaiTest.verticalJump
              ? _plantedHip(_ankleX0, _rig.ankleHeight + _rig.shinLen * kTiptoeShinRatio, 0, 0)
              : _hip0;
          hip = (h0.$1 + _vx * tau, h0.$2 + _v0y * tau - kGravity * tau * tau / 2);
          if (test == SaiTest.verticalJump) {
            // Keep the leg geometry rigid in flight so ankle and hip rise together.
            final off = _plantedHip(0, 0, v[0], v[1]);
            final base = _plantedHip(0, 0, 0, 0);
            hip = (hip.$1 + off.$1 - base.$1, hip.$2 + off.$2 - base.$2);
          }
        } else {
          final ax = t < _tTakeoff || test == SaiTest.verticalJump ? _ankleX0 : _ankleXLand;
          hip = _plantedHip(ax, _rig.ankleHeight + tiptoe, v[0], v[1]);
        }
        pose = RigPose(
          hipX: hip.$1,
          hipY: hip.$2,
          torso: v[2],
          upperArmL: v[3],
          forearmL: v[4],
          upperArmR: v[5],
          forearmR: v[6],
          thighL: v[0],
          shinL: v[1],
          thighR: v[0],
          shinR: v[1],
        );
      case SaiTest.sitAndReach:
        var reach = 0.0;
        var torso = _pi - 0.1;
        for (final (start, hold, tor) in _reachPlan) {
          if (t >= start && t <= start + 1.0 + hold + 0.8) {
            torso = tor;
            reach = t < start + 1.0
                ? smoothstep(start, start + 1.0, t)
                : (t < start + 1.0 + hold ? 1.0 : 1 - smoothstep(start + 1.0 + hold, start + 1.8 + hold, t));
          }
        }
        pose = _sitPose(torso, reach);
      default:
        throw StateError('unsupported');
    }
    return renderRig(rig: _rig, pose: pose, cam: cam, noise: _noise, tMs: tMs, index: index, pixelSigma: 0.9);
  }

  @override
  List<HudPrimitive> scenery(double tMs) {
    final floor = HudLine(cam.project(-3, 0), cam.project(5, 0), tone: HudTone.neutral, width: 3);
    switch (test) {
      case SaiTest.height:
      case SaiTest.verticalJump:
        return [floor, HudLine(cam.project(-0.7, 0), cam.project(-0.7, 2.6), tone: HudTone.neutral, width: 1)];
      case SaiTest.broadJump:
        return [
          HudLine(cam.project(-1, 0, 0), cam.project(4, 0, 0), tone: HudTone.neutral, width: 2),
          HudLine(cam.project(-1, 0, 0.6), cam.project(4, 0, 0.6), tone: HudTone.neutral, width: 1),
        ];
      case SaiTest.sitAndReach:
        final x0 = _footLineX;
        return [
          floor,
          HudPolygon([
            cam.project(x0, 0),
            cam.project(x0 + 0.55, 0),
            cam.project(x0 + 0.55, 0.32),
            cam.project(x0 - 0.15, 0.32),
            cam.project(x0 - 0.15, 0.30),
            cam.project(x0, 0.30),
          ], tone: HudTone.neutral),
        ];
      default:
        return [floor];
    }
  }

  @override
  Map<String, Object?> get groundTruth => _truth;
}

/// Builds the right measurement session for a jump/reach test.
MeasurementSession createJumpReachSession(
  SaiTest test,
  CalibrationResult cal, {
  double? athleteHeightCm,
  bool lenient = false,
}) =>
    switch (test) {
      SaiTest.height => HeightSession(cal, lenient: lenient),
      SaiTest.verticalJump => VerticalJumpSession(cal),
      SaiTest.broadJump => BroadJumpSession(cal, athleteHeightCm: athleteHeightCm),
      // Live: KHOJ floor-tape protocol. The marker's left edge sits on the heel
      // line (the tape's 23 cm mark), so score = 23 + cm beyond the heels, and
      // the hold is 2 s. Simulation keeps its original geometry (0 at the heels, 1.5 s).
      SaiTest.sitAndReach => cal.simulated
          ? SitReachSession(cal)
          : SitReachSession(
              cal,
              reachOffsetCm: SitReachSession.heelLineCm,
              // KHOJ: hold 2 s. Lenient: 1 s within a wider band.
              holdMs: lenient ? 1000 : 2000,
              lenient: lenient,
            ),
      _ => throw ArgumentError('${test.id} is not a jump/reach test'),
    };
