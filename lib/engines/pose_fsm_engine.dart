/// Module B: Sit-Ups finite state machine with foul rejection.
///
/// States: flatBack → ascending → peakElbowTouch → descending → flatBack (rep).
///
/// A rep counts only if, during that rep:
///  * the hands stay locked behind the head (wrist closer to the head than the elbow),
///  * the elbows reach the knees at the peak,
///  * the shoulder blades return flat before the next ascent.
/// Otherwise the rep is rejected and the foul is logged.
///
/// Simulation Mode: [SitUpSimulator] animates a side-view athlete with natural
/// rep-to-rep variation, fatigue, and randomly injected fouls of each type.
library;

import 'dart:math' as math;

import '../core/domain/sai_test.dart';
import 'pose_types.dart';

enum SitUpState { flatBack, ascending, peakElbowTouch, descending }

class SitUpThresholds {
  const SitUpThresholds({
    // Real lying athletes read 5–20° "flat" (shoulders sit on the clasped hands
    // and MoveNet's shoulder point drifts on horizontal bodies), so flat < 25°
    // with a 10° gap to the ascent trigger.
    this.flatDeg = 25,
    this.ascendDeg = 35,
    this.peakMinTorsoDeg = 55,
    // Joint centres stay apart even when the elbow touches the knee
    // (elbow tip to knee top), so the old 0.42 thigh-lengths missed real touches.
    this.elbowKneeRatio = 0.55,
    this.handsDetachRatio = 0.25,
    this.handsDetachMs = 250,
    this.handsFoulVoids = true,
    this.handsMinScore = 0.5,
    this.descendDropDeg = 10,
    this.reAscendDeg = 12,
    this.emaAlpha = 0.5,
    this.minKeypointScore = 0.3,
    this.uprightTouchDeg = 999,
    this.name = 'strict',
  });

  /// Wider tolerances for live use while thresholds are tuned on real athletes.
  /// Touch and flat-return still void a rep, with more slack: "flat" up to 38°,
  /// a touch at up to 0.8 thigh lengths or simply by sitting up to 62°.
  /// Hands leaving the head are only flagged (not voided) until the hands
  /// check is validated on real athletes.
  const SitUpThresholds.lenient()
      : this(
          flatDeg: 38,
          ascendDeg: 46,
          peakMinTorsoDeg: 45,
          elbowKneeRatio: 0.8,
          uprightTouchDeg: 62,
          handsDetachRatio: 0.35,
          handsDetachMs: 400,
          handsFoulVoids: false,
          handsMinScore: 0.6,
          descendDropDeg: 12,
          reAscendDeg: 18,
          minKeypointScore: 0.2,
          name: 'lenient',
        );

  /// The v1.0.0 numbers the simulator's synthetic athlete was tuned with.
  const SitUpThresholds.simulator()
      : this(
          flatDeg: 18,
          ascendDeg: 26,
          peakMinTorsoDeg: 55,
          elbowKneeRatio: 0.42,
          handsDetachRatio: 0.2,
          handsDetachMs: 90,
          handsMinScore: 0.3,
          descendDropDeg: 10,
          reAscendDeg: 8,
          name: 'simulator',
        );

  /// Torso below this angle to the floor counts as flat.
  final double flatDeg;

  /// Torso above this starts an ascent.
  final double ascendDeg;

  /// Torso must also be at least this upright for a valid elbow-knee touch.
  final double peakMinTorsoDeg;

  /// Elbow–knee distance / thigh length below this counts as a touch.
  final double elbowKneeRatio;

  /// Hands count as detached when the wrist is farther from the head than the
  /// elbow is, by more than this many torso lengths. Clasped behind the head
  /// the wrist is much closer to the head than the elbow (negative margin);
  /// a hidden wrist guessed near the elbow reads about 0; a hand swung forward
  /// to push off the knee reads +0.5 or more. Relative, so it does not depend
  /// on foreshortened arm lengths.
  final double handsDetachRatio;

  /// Whether hands leaving the head voids the rep (strict SAI) or is only
  /// flagged on the rep for review (lenient demo rules).
  final bool handsFoulVoids;

  /// The wrist must stay that far away for this long (ms), not just a few frames.
  final double handsDetachMs;

  /// Only a clearly seen wrist can prove a foul. Behind the head the wrist is
  /// usually hidden and the model's guess (often near the elbow) is unreliable.
  final double handsMinScore;

  /// Drop from the rep's max torso angle that marks the descent.
  final double descendDropDeg;

  /// Rise from the descent's minimum (while not flat) that marks a premature re-ascent.
  final double reAscendDeg;
  final double emaAlpha;
  final double minKeypointScore;

  /// Sitting up at least this far counts as reaching the knees even if the
  /// elbow-knee distance was not seen closing (999 = never; strict rule set).
  final double uprightTouchDeg;

  /// Rule set name, saved with every result.
  final String name;
}

class SitUpRep {
  SitUpRep(this.startMs);
  final double startMs;
  double? endMs;
  double maxTorsoDeg = 0;
  double minElbowKnee = double.infinity;
  /// Lowest torso angle between the peak and the next rep (how flat it got).
  double? bottomTorsoDeg;
  bool touched = false;
  final Set<String> fouls = {};
  /// Observations that did not void the rep (lenient rules), e.g. hands.
  final Set<String> flags = {};
  bool get valid => fouls.isEmpty && touched;

  Map<String, Object?> toJson() => {
        'startMs': startMs.round(),
        'endMs': endMs?.round(),
        'maxTorsoDeg': maxTorsoDeg.round(),
        'minElbowKnee': minElbowKnee.isFinite ? double.parse(minElbowKnee.toStringAsFixed(2)) : null,
        'bottomTorsoDeg': bottomTorsoDeg?.round(),
        'touched': touched,
        'valid': valid,
        'fouls': fouls.toList(),
        'flags': flags.toList(),
      };
}

class SitUpSession implements MeasurementSession {
  SitUpSession({
    this.thresholds = const SitUpThresholds(),
    int? durationSec,
    this.waitForGo = false,
  }) : durationMs = (durationSec ?? SaiTest.sitUps.durationSec!) * 1000.0;

  final SitUpThresholds thresholds;
  final double durationMs;

  /// When true, nothing is counted and the timer does not run until [startAt]
  /// is called on the assessor's "Go" (SAI: the watch starts on the word "go").
  /// When false (simulation), the timer starts on the first confident frame.
  final bool waitForGo;

  /// Time of "Go" on the frame clock ([PoseFrame.tMs]), once given.
  double? get goMs => _goMs;
  double? _goMs;

  /// Starts the test window at [tMs] (same clock as [PoseFrame.tMs]).
  void startAt(double tMs) {
    if (_goMs != null || _complete) return;
    _goMs = tMs;
    _startMs = tMs;
  }

  @override
  SaiTest get test => SaiTest.sitUps;

  SitUpState _state = SitUpState.flatBack;
  SitUpState get state => _state;

  final reps = <SitUpRep>[];
  SitUpRep? _current;
  double? _startMs;
  double? _torsoEma;
  final _ekWindow = <double>[];
  double _descentMin = 90;
  double? _detachSinceMs;
  int _frames = 0;
  int _lowConfidenceFrames = 0;
  final _scores = <double>[];
  bool _complete = false;
  double _lastT = 0;
  final _fouls = <String>[];

  int get validReps => reps.where((r) => r.valid).length;

  @override
  bool get isComplete => _complete;

  @override
  EngineSnapshot process(PoseFrame f) {
    _lastT = f.tMs;
    if (_complete) return _snapshot(f, const []);
    // Before "Go" (and for frames captured before it), only show the countdown state.
    if (waitForGo && (_goMs == null || f.tMs < _goMs!)) {
      return _snapshot(f, const [], waiting: true);
    }
    // The window is a fixed clock: it must close on time even if tracking drops out.
    if (_startMs != null && f.tMs - _startMs! >= durationMs) {
      _closeOpenRep(f.tMs, timeUp: true);
      _complete = true;
      return _snapshot(f, const []);
    }
    _frames++;

    // Lock the camera-facing side once; per-frame switching made angles jump.
    final s = _lockSide(f);
    final shoulder = f.side(s, KP.leftShoulder), hip = f.side(s, KP.leftHip);
    final knee = f.side(s, KP.leftKnee), elbow = f.side(s, KP.leftElbow);
    // Hands are clasped, so either wrist will do: take the better-seen one.
    // Same for the ear (the near ear is often hidden by the arm).
    final wrist = f[KP.leftWrist].score >= f[KP.rightWrist].score ? f[KP.leftWrist] : f[KP.rightWrist];
    final ear = f[KP.leftEar].score >= f[KP.rightEar].score ? f[KP.leftEar] : f[KP.rightEar];
    // Counting needs only the body: wrists and ears behind the head are often
    // hidden, and must not freeze the count.
    final tracked = [shoulder, hip, knee, elbow];
    final score = mean(tracked.map((k) => k.score));
    _scores.add(score);
    if (tracked.any((k) => k.score < thresholds.minKeypointScore)) {
      _lowConfidenceFrames++;
      return _snapshot(f, const []); // hold the state through a dropout
    }

    // Without "Go", the timer starts when the athlete is first seen clearly.
    _startMs ??= f.tMs;

    final v = shoulder.p - hip.p;
    final torsoRaw = math.atan2(-v.y, v.x.abs()) * 180 / math.pi;
    final thigh = math.max(hip.p.distanceTo(knee.p), 1.0);
    final torsoLen = math.max(hip.p.distanceTo(shoulder.p), 1.0);
    // Head: the better-seen ear, else the nose, else extend the torso line
    // past the shoulder by 35%.
    final nose = f[KP.nose];
    final head = ear.score >= thresholds.minKeypointScore
        ? ear.p
        : nose.score >= thresholds.minKeypointScore
            ? nose.p
            : shoulder.p + (shoulder.p - hip.p) * 0.35;
    final wristSeen = wrist.score >= thresholds.handsMinScore;
    final a = thresholds.emaAlpha;
    _torsoEma = _torsoEma == null ? torsoRaw : _torsoEma! + a * (torsoRaw - _torsoEma!);
    // Elbow-knee: median of the last 3 raw frames. Rejects single-frame
    // jitter without the lag of an EMA, which used to hide brief real touches.
    _ekWindow.add(elbow.p.distanceTo(knee.p) / thigh);
    if (_ekWindow.length > 3) _ekWindow.removeAt(0);
    final ek = ([..._ekWindow]..sort())[_ekWindow.length ~/ 2];
    final torso = _torsoEma!;
    // Hands margin (torso lengths): how much farther the wrist is from the
    // head than the elbow is. Negative while the hands are clasped.
    final handsMargin =
        wristSeen ? (wrist.p.distanceTo(head) - elbow.p.distanceTo(head)) / torsoLen : -1.0;
    final handsAway = wristSeen && handsMargin > thresholds.handsDetachRatio;

    // Hands-behind-head check runs through the whole rep.
    if (_current != null) {
      // Foul only on clear evidence: wrist well seen AND away for handsDetachMs.
      if (handsAway) {
        _detachSinceMs ??= f.tMs;
        if (f.tMs - _detachSinceMs! >= thresholds.handsDetachMs) {
          (thresholds.handsFoulVoids ? _current!.fouls : _current!.flags).add('foul_hands_detached');
        }
      } else {
        _detachSinceMs = null;
      }
      _current!.maxTorsoDeg = math.max(_current!.maxTorsoDeg, torso);
      _current!.minElbowKnee = math.min(_current!.minElbowKnee, ek);
      // The touch can register at any point of the rep (up, top or on the
      // way down): the knee is reached at the turn-around, often between frames.
      if (!_current!.touched &&
          ((ek < thresholds.elbowKneeRatio && _current!.maxTorsoDeg >= thresholds.peakMinTorsoDeg) ||
              torso >= thresholds.uprightTouchDeg)) {
        _current!.touched = true;
      }
    }

    switch (_state) {
      case SitUpState.flatBack:
        if (torso > thresholds.ascendDeg) {
          _current = SitUpRep(f.tMs);
          _detachSinceMs = null;
          _state = SitUpState.ascending;
        }
      case SitUpState.ascending:
        if (_current!.touched) {
          _state = SitUpState.peakElbowTouch;
        } else if (torso < _current!.maxTorsoDeg - thresholds.descendDropDeg) {
          // Turning back. A late touch can still register on the way down;
          // "elbows short" is decided when the rep closes.
          _state = SitUpState.descending;
          _descentMin = torso;
        }
      case SitUpState.peakElbowTouch:
        if (torso < _current!.maxTorsoDeg - thresholds.descendDropDeg) {
          _state = SitUpState.descending;
          _descentMin = torso;
        }
      case SitUpState.descending:
        _descentMin = math.min(_descentMin, torso);
        _current!.bottomTorsoDeg = _descentMin;
        if (torso <= thresholds.flatDeg) {
          _closeOpenRep(f.tMs);
          _state = SitUpState.flatBack;
        } else if (torso > _descentMin + thresholds.reAscendDeg) {
          // Started the next sit-up before the shoulder blades touched down.
          _current!.fouls.add('foul_back_not_flat');
          _closeOpenRep(f.tMs);
          _current = SitUpRep(f.tMs);
          _detachSinceMs = null;
          _state = SitUpState.ascending;
        }
    }

    final overlay = <HudPrimitive>[
      HudLine(hip.p, shoulder.p,
          tone: torso <= thresholds.flatDeg ? HudTone.pass : HudTone.primary,
          width: 4,
          label: '${torso.round()}°'),
      HudLine(elbow.p, knee.p,
          dashed: true,
          tone: ek < thresholds.elbowKneeRatio ? HudTone.pass : HudTone.neutral,
          label: ek.toStringAsFixed(2)),
      if (wristSeen)
        HudPoint(wrist.p, tone: handsAway ? HudTone.foul : HudTone.pass, radius: 7),
    ];
    return _snapshot(f, overlay);
  }

  int? _side;

  /// Side (0 left, 1 right) whose shoulder/hip/knee/elbow are better seen.
  /// Chosen on the first clear frame; switched only if it becomes unusable
  /// while the other side is fully visible.
  int _lockSide(PoseFrame f) {
    double sideScore(int s) => [KP.leftShoulder, KP.leftHip, KP.leftKnee, KP.leftElbow]
        .map((k) => f.side(s, k).score)
        .reduce(math.min);
    final l = sideScore(0), r = sideScore(1);
    final best = l >= r ? 0 : 1;
    if (_side == null) {
      if (math.max(l, r) >= thresholds.minKeypointScore) _side = best;
      return best;
    }
    final cur = _side == 0 ? l : r, other = _side == 0 ? r : l;
    if (cur < thresholds.minKeypointScore && other >= thresholds.minKeypointScore) _side = 1 - _side!;
    return _side!;
  }

  void _closeOpenRep(double t, {bool timeUp = false}) {
    final r = _current;
    if (r == null) return;
    r.endMs = t;
    // A rep cut off by the whistle only counts if it already touched and returned.
    if (timeUp && _state != SitUpState.flatBack) {
      _current = null;
      return;
    }
    if (!r.touched && !r.fouls.contains('foul_elbows_short')) r.fouls.add('foul_elbows_short');
    reps.add(r);
    _fouls.addAll(r.fouls);
    _current = null;
  }

  EngineSnapshot _snapshot(PoseFrame f, List<HudPrimitive> overlay, {bool waiting = false}) {
    final elapsed = _startMs == null ? 0.0 : (f.tMs - _startMs!).clamp(0.0, durationMs);
    final left = ((durationMs - elapsed) / 1000).ceil();
    final phase = switch (_state) {
      SitUpState.flatBack => 'phase_flat_back',
      SitUpState.ascending => 'phase_ascending',
      SitUpState.peakElbowTouch => 'phase_peak',
      SitUpState.descending => 'phase_descending',
    };
    return EngineSnapshot(
      phaseKey: _complete
          ? 'phase_finished'
          : waiting
              ? 'phase_wait_go'
              : phase,
      primary: '$validReps',
      primaryLabelKey: 'wb_valid_reps',
      secondary: reps.isEmpty ? '${left}s' : '${left}s · ${_repSummary(reps.last)}',
      overlay: overlay,
      fouls: List.unmodifiable(_fouls),
      complete: _complete,
      progress: elapsed / durationMs,
    );
  }

  /// Short on-screen summary of a closed rep: peak angle, closest elbow-knee
  /// ratio, and whether it counted, e.g. "#7 64° 0.48 ✓".
  String _repSummary(SitUpRep r) {
    final ek = r.minElbowKnee.isFinite ? r.minElbowKnee.toStringAsFixed(2) : '–';
    // Symbols only (no words to translate); the reason for a ✗ is already
    // shown as a localized foul message. "✓?" = counted, hands flagged.
    final mark = !r.valid ? '✗' : (r.flags.isEmpty ? '✓' : '✓?');
    return '#${reps.length} ${r.maxTorsoDeg.round()}° $ek $mark';
  }

  @override
  AttemptOutcome finalize() {
    if (!_complete) _closeOpenRep(_lastT, timeUp: true);
    _complete = true;
    final total = reps.length;
    final kp = _scores.isEmpty ? 0.0 : mean(_scores);
    final dropout = _frames == 0 ? 1.0 : _lowConfidenceFrames / _frames;
    // Confidence: keypoint quality, dropout rate, and how decisive each rep was.
    final decisiveness = total == 0
        ? 0.5
        : mean(reps.map((r) => r.touched
            ? (1 - (r.minElbowKnee / thresholds.elbowKneeRatio)).clamp(0.0, 1.0) * 0.5 + 0.5
            : 0.8));
    final conf = (100 * kp.clamp(0.0, 1.0) * (1 - dropout) * decisiveness + 8).clamp(5.0, 99.0);
    final foulCounts = <String, int>{};
    final flagCounts = <String, int>{};
    for (final r in reps) {
      for (final fl in r.fouls) {
        foulCounts[fl] = (foulCounts[fl] ?? 0) + 1;
      }
      for (final fl in r.flags) {
        flagCounts[fl] = (flagCounts[fl] ?? 0) + 1;
      }
    }
    return AttemptOutcome(
      test: test,
      value: _startMs == null ? null : validReps.toDouble(),
      confidence: conf,
      fouls: foulCounts.keys.toList(),
      metadata: {
        'validReps': validReps,
        'attemptedReps': total,
        'rejectedReps': total - validReps,
        'foulCounts': foulCounts,
        'flagCounts': flagCounts,
        'reps': reps.map((r) => r.toJson()).toList(),
        'durationSec': durationMs / 1000,
        'rules': thresholds.name,
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Simulation
// ---------------------------------------------------------------------------

class _SimRep {
  _SimRep(this.start, this.duration, this.peakPhi, this.bottomPhi,
      {this.handsDetach = false});
  final double start, duration, peakPhi, bottomPhi;
  final bool handsDetach;
}

class SitUpSimulator extends FrameSimulator {
  SitUpSimulator({int seed = 42, this.statureM = 1.55, int? durationSec})
      : _testMs = (durationSec ?? SaiTest.sitUps.durationSec!) * 1000.0,
        _noise = SimNoise(seed),
        _rig = SideRig(statureM) {
    _cam = SimCamera(width: 720, height: 1280, focalPx: 1150, position: (0.15, 0.45, -2.6));
    _plan();
  }

  final double statureM;
  final SimNoise _noise;
  final SideRig _rig;
  late final SimCamera _cam;
  final _reps = <_SimRep>[];
  int _expectedValid = 0;

  static const _leadInMs = 1200.0;
  final double _testMs;

  @override
  SaiTest get test => SaiTest.sitUps;
  @override
  double get width => _cam.width;
  @override
  double get height => _cam.height;
  @override
  double get fps => 30;
  @override
  double get durationMs => _testMs + 800;

  void _plan() {
    var t = _leadInMs + 400;
    var i = 0;
    while (t < _testMs + 2500) {
      final fatigue = 1 + i * 0.025;
      final dur = _noise.uniform(1450, 1850) * fatigue;
      final roll = _noise.uniform(0, 1);
      final elbowsShort = roll < 0.10;
      final notFlat = roll >= 0.10 && roll < 0.18;
      final detach = roll >= 0.18 && roll < 0.27;
      final rep = _SimRep(
        t,
        dur,
        elbowsShort ? _noise.uniform(0.95, 1.05) : _noise.uniform(1.45, 1.55),
        notFlat ? 0.55 : 0.0,
        handsDetach: detach,
      );
      _reps.add(rep);
      // The session timer starts on the first frame, so the 30 s window is [0, testMs].
      final endsInTime = t + dur <= _testMs;
      // Ground truth applies the SAI rule set: valid = touched, flat return, hands locked.
      if (endsInTime && !elbowsShort && !notFlat && !detach) _expectedValid++;
      t += dur + (notFlat ? 0 : _noise.uniform(50, 250));
      i++;
    }
  }

  /// Torso elevation φ (rad) and the active rep at time t.
  (double, _SimRep?) _phiAt(double t) {
    for (var i = 0; i < _reps.length; i++) {
      final r = _reps[i];
      if (t < r.start) return (i == 0 ? 0.0 : _reps[i - 1].bottomPhi, null);
      if (t <= r.start + r.duration) {
        final from = i == 0 ? 0.0 : _reps[i - 1].bottomPhi;
        final u = (t - r.start) / r.duration;
        final phi = u < 0.48
            ? lerpD(from, r.peakPhi, smoothstep(0, 0.48, u))
            : lerpD(r.peakPhi, r.bottomPhi, smoothstep(0.52, 1, u));
        return (phi, r);
      }
    }
    return (0, null);
  }

  @override
  PoseFrame frameAt(double tMs, int index) {
    final (phi, rep) = _phiAt(tMs);
    final pose = RigPose(
      hipX: 0,
      hipY: 0.10,
      facing: 1,
      torso: -math.pi / 2 - phi,
      thighL: math.pi / 2 + 0.9,
      shinL: math.pi / 2 - 0.85,
      thighR: math.pi / 2 + 0.88,
      shinR: math.pi / 2 - 0.83,
    );
    final j = _rig.joints(pose);
    final sh = j[KP.leftShoulder]!, knee = j[KP.leftKnee]!;
    final u = (-math.cos(phi), math.sin(phi)); // hip → shoulder
    final n = (u.$2, -u.$1); // chest-forward
    final toKnee = Vec2(knee.$1 - sh.$1, knee.$2 - sh.$2).normalized;
    final reach = smoothstep(0.85, 1.45, phi);
    final elbowDir = Vec2.lerp(Vec2(u.$1 * 0.45 + n.$1 * 0.89, u.$2 * 0.45 + n.$2 * 0.89), toKnee, reach).normalized;
    final elbow = (sh.$1 + elbowDir.x * _rig.upperArmLen, sh.$2 + elbowDir.y * _rig.upperArmLen);
    var wrist = (sh.$1 + u.$1 * 0.075 * statureM - n.$1 * 0.03 * statureM,
        sh.$2 + u.$2 * 0.075 * statureM - n.$2 * 0.03 * statureM);
    if (rep != null && rep.handsDetach) {
      final w = smoothstep(0.15, 0.4, (tMs - rep.start) / rep.duration) *
          (1 - smoothstep(0.6, 0.85, (tMs - rep.start) / rep.duration));
      final swung = (sh.$1 + toKnee.x * 0.30 * statureM, sh.$2 + toKnee.y * 0.30 * statureM);
      wrist = (lerpD(wrist.$1, swung.$1, w), lerpD(wrist.$2, swung.$2, w));
    }
    final far = 0.012 * statureM;
    return renderRig(
      rig: _rig,
      pose: pose,
      cam: _cam,
      noise: _noise,
      tMs: tMs,
      index: index,
      jointOverrides: {
        KP.leftElbow: elbow,
        KP.rightElbow: (elbow.$1 - far, elbow.$2),
        KP.leftWrist: wrist,
        KP.rightWrist: (wrist.$1 - far, wrist.$2),
      },
    );
  }

  @override
  List<HudPrimitive> scenery(double tMs) => [
        HudLine(_cam.project(-1.5, 0), _cam.project(1.5, 0), tone: HudTone.neutral, width: 3),
      ];

  @override
  Map<String, Object?> get groundTruth => {
        'expectedValidReps': _expectedValid,
        'plannedReps': _reps.where((r) => r.start + r.duration <= _testMs).length,
      };
}
