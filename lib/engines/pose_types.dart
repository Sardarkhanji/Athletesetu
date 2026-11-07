/// Shared, Flutter-free types for every engine.
///
/// Coordinates are **image pixels** of the upright (display-oriented) frame,
/// x to the right, y downwards. Engines never import Flutter, so they run inside
/// isolates and in plain `dart test`.
library;

import 'dart:math' as math;

import '../core/domain/sai_test.dart';

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

class Vec2 {
  const Vec2(this.x, this.y);
  final double x;
  final double y;

  static const zero = Vec2(0, 0);

  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);
  Vec2 operator /(double s) => Vec2(x / s, y / s);

  double get length => math.sqrt(x * x + y * y);
  double distanceTo(Vec2 o) => (this - o).length;
  double dot(Vec2 o) => x * o.x + y * o.y;
  double cross(Vec2 o) => x * o.y - y * o.x;
  Vec2 get normalized {
    final l = length;
    return l == 0 ? Vec2.zero : this / l;
  }

  Vec2 rotate(double rad) {
    final c = math.cos(rad), s = math.sin(rad);
    return Vec2(x * c - y * s, x * s + y * c);
  }

  static Vec2 lerp(Vec2 a, Vec2 b, double t) => a + (b - a) * t;
  static Vec2 mid(Vec2 a, Vec2 b) => Vec2((a.x + b.x) / 2, (a.y + b.y) / 2);

  List<double> toList() => [x, y];
  static Vec2 fromList(List<dynamic> l) => Vec2((l[0] as num).toDouble(), (l[1] as num).toDouble());

  @override
  String toString() => '(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// Angle ABC in degrees (at vertex b).
double angleDeg(Vec2 a, Vec2 b, Vec2 c) {
  final v1 = a - b, v2 = c - b;
  final d = v1.length * v2.length;
  if (d == 0) return 180;
  return math.acos((v1.dot(v2) / d).clamp(-1.0, 1.0)) * 180 / math.pi;
}

double median(List<double> v) {
  if (v.isEmpty) return double.nan;
  final s = [...v]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

double mean(Iterable<double> v) {
  var n = 0;
  var sum = 0.0;
  for (final x in v) {
    sum += x;
    n++;
  }
  return n == 0 ? double.nan : sum / n;
}

double stdDev(List<double> v) {
  if (v.length < 2) return 0;
  final m = mean(v);
  return math.sqrt(v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / (v.length - 1));
}

/// Standard gravity (m/s²).
const double kGravity = 9.80665;

/// Anthropometric ratios (fraction of stature) shared by engines and simulators.
const double kHeelBehindAnkleRatio = 0.035;

/// Ankle-joint rise when on the toes at take-off, as a fraction of shin length.
const double kTiptoeShinRatio = 0.12;

// ---------------------------------------------------------------------------
// Pose
// ---------------------------------------------------------------------------

/// MoveNet / COCO-17 keypoint indices.
abstract final class KP {
  static const nose = 0, leftEye = 1, rightEye = 2, leftEar = 3, rightEar = 4;
  static const leftShoulder = 5, rightShoulder = 6, leftElbow = 7, rightElbow = 8;
  static const leftWrist = 9, rightWrist = 10, leftHip = 11, rightHip = 12;
  static const leftKnee = 13, rightKnee = 14, leftAnkle = 15, rightAnkle = 16;
  static const count = 17;

  /// Skeleton edges for the HUD.
  static const edges = <(int, int)>[
    (leftEar, leftEye), (leftEye, nose), (nose, rightEye), (rightEye, rightEar),
    (leftShoulder, rightShoulder), (leftShoulder, leftElbow), (leftElbow, leftWrist),
    (rightShoulder, rightElbow), (rightElbow, rightWrist), (leftShoulder, leftHip),
    (rightShoulder, rightHip), (leftHip, rightHip), (leftHip, leftKnee),
    (leftKnee, leftAnkle), (rightHip, rightKnee), (rightKnee, rightAnkle),
  ];
}

class Keypoint {
  const Keypoint(this.p, this.score);
  final Vec2 p;
  final double score;

  static const missing = Keypoint(Vec2.zero, 0);
}

/// One analysed frame (from the camera isolate or a simulator).
class PoseFrame {
  const PoseFrame({
    required this.tMs,
    required this.width,
    required this.height,
    required this.keypoints,
    this.ball,
    this.silhouetteTop,
    this.silhouetteBottom,
    this.index = 0,
  });

  /// Monotonic capture time in milliseconds.
  final double tMs;
  final double width;
  final double height;

  /// 17 keypoints (score 0 when not detected).
  final List<Keypoint> keypoints;

  /// Ball centre (medicine-ball throw), if tracked.
  final Vec2? ball;

  /// Topmost / bottom-most foreground pixel of the athlete (background subtraction).
  final Vec2? silhouetteTop;
  final Vec2? silhouetteBottom;

  final int index;

  Keypoint operator [](int i) => keypoints[i];

  bool get hasPerson => meanScore >= 0.25;

  double get meanScore => mean(keypoints.map((k) => k.score));

  /// Mean score of a subset.
  double scoreOf(List<int> idx) => mean(idx.map((i) => keypoints[i].score));

  Vec2 midpoint(int a, int b) => Vec2.mid(keypoints[a].p, keypoints[b].p);

  /// Torso midpoint: mean of both shoulders and both hips (ignores limbs).
  Vec2 get torsoCenter {
    final s = midpoint(KP.leftShoulder, KP.rightShoulder);
    final h = midpoint(KP.leftHip, KP.rightHip);
    return Vec2.mid(s, h);
  }

  /// Side (left=0/right=1) whose arm+leg keypoints are more confident.
  int get nearSide {
    final l = scoreOf([KP.leftShoulder, KP.leftElbow, KP.leftWrist, KP.leftHip, KP.leftKnee]);
    final r = scoreOf([KP.rightShoulder, KP.rightElbow, KP.rightWrist, KP.rightHip, KP.rightKnee]);
    return l >= r ? 0 : 1;
  }

  Keypoint side(int side, int leftIndex) => keypoints[leftIndex + side];

  /// Estimated fingertip: MoveNet has no hand points, so the hand is extended
  /// along the forearm by 0.75× forearm length (anthropometric hand/forearm ratio).
  Vec2 fingertip(int side) {
    final w = keypoints[KP.leftWrist + side].p;
    final e = keypoints[KP.leftElbow + side].p;
    return w + (w - e) * 0.75;
  }

  Map<String, Object?> toJson() => {
        't': tMs,
        'w': width,
        'h': height,
        'k': [for (final k in keypoints) [k.p.x, k.p.y, k.score]],
        if (ball != null) 'b': ball!.toList(),
        if (silhouetteTop != null) 'st': silhouetteTop!.toList(),
        if (silhouetteBottom != null) 'sb': silhouetteBottom!.toList(),
        'i': index,
      };

  static PoseFrame fromJson(Map<String, Object?> j) => PoseFrame(
        tMs: (j['t'] as num).toDouble(),
        width: (j['w'] as num).toDouble(),
        height: (j['h'] as num).toDouble(),
        keypoints: [
          for (final k in (j['k'] as List))
            Keypoint(Vec2((k[0] as num).toDouble(), (k[1] as num).toDouble()), (k[2] as num).toDouble()),
        ],
        ball: j['b'] == null ? null : Vec2.fromList(j['b'] as List),
        silhouetteTop: j['st'] == null ? null : Vec2.fromList(j['st'] as List),
        silhouetteBottom: j['sb'] == null ? null : Vec2.fromList(j['sb'] as List),
        index: (j['i'] as int?) ?? 0,
      );
}

// ---------------------------------------------------------------------------
// HUD overlay primitives (rendered by the camera workbench CustomPainter)
// ---------------------------------------------------------------------------

enum HudTone { neutral, primary, pass, warning, foul }

sealed class HudPrimitive {
  const HudPrimitive({this.tone = HudTone.primary, this.label});
  final HudTone tone;
  final String? label;
}

class HudLine extends HudPrimitive {
  const HudLine(this.a, this.b, {super.tone, super.label, this.dashed = false, this.width = 2});
  final Vec2 a;
  final Vec2 b;
  final bool dashed;
  final double width;
}

class HudPoint extends HudPrimitive {
  const HudPoint(this.p, {super.tone, super.label, this.radius = 6});
  final Vec2 p;
  final double radius;
}

class HudPolygon extends HudPrimitive {
  const HudPolygon(this.points, {super.tone, super.label, this.fill = false});
  final List<Vec2> points;
  final bool fill;
}

class HudPath extends HudPrimitive {
  const HudPath(this.points, {super.tone, super.label});
  final List<Vec2> points;
}

// ---------------------------------------------------------------------------
// Session contracts
// ---------------------------------------------------------------------------

/// Live state shown on the HUD after each frame.
class EngineSnapshot {
  const EngineSnapshot({
    required this.phaseKey,
    this.phaseParams = const {},
    this.primary,
    this.primaryLabelKey,
    this.secondary,
    this.overlay = const [],
    this.fouls = const [],
    this.complete = false,
    this.progress,
  });

  /// Localization key of the current phase (e.g. `phase_flight`).
  final String phaseKey;
  final Map<String, Object?> phaseParams;

  /// Big live number (formatted, tabular), e.g. "12" reps or "4.81" s.
  final String? primary;
  final String? primaryLabelKey;
  final String? secondary;
  final List<HudPrimitive> overlay;

  /// Localization keys of fouls detected so far in this attempt.
  final List<String> fouls;
  final bool complete;

  /// 0..1 for fixed-duration tests.
  final double? progress;

  static const idle = EngineSnapshot(phaseKey: 'phase_idle');
}

/// Final result of one attempt, before human confirmation.
class AttemptOutcome {
  const AttemptOutcome({
    required this.test,
    required this.value,
    required this.confidence,
    this.fouls = const [],
    this.metadata = const {},
    this.requiresScrub = false,
  });

  final SaiTest test;

  /// Null when nothing measurable happened (shown as "—", manual entry only).
  final double? value;

  /// 0–100.
  final double confidence;
  final List<String> fouls;
  final Map<String, Object?> metadata;

  /// Medicine ball: must be confirmed on the frame scrubber first.
  final bool requiresScrub;

  bool get isValid => value != null;
}

/// A per-attempt measurement state machine fed frame by frame.
abstract class MeasurementSession {
  SaiTest get test;
  EngineSnapshot process(PoseFrame frame);
  bool get isComplete;

  /// Builds the outcome; call when [isComplete] or when the assessor stops.
  AttemptOutcome finalize();
}

/// Generates synthetic frames that exercise the real engine algorithms.
abstract class FrameSimulator {
  SaiTest get test;
  double get width;
  double get height;

  /// Simulated capture rate.
  double get fps;

  /// Simulated seconds per wall-clock second (endurance runs are accelerated).
  double get timeScale => 1;

  /// Total simulated duration in ms.
  double get durationMs;

  /// The frame at simulated time [tMs].
  PoseFrame frameAt(double tMs, int index);

  /// Projected scene geometry for the HUD (floor line, wall, markers, ball…).
  List<HudPrimitive> scenery(double tMs) => const [];

  /// What the simulator *actually* did, for on-screen accuracy comparison.
  Map<String, Object?> get groundTruth;
}

// ---------------------------------------------------------------------------
// Simulation helpers: pinhole camera + side-view humanoid rig
// ---------------------------------------------------------------------------

/// World: X right (m), Y up (m), Z away from the camera (m). The athlete moves in Z=0.
class SimCamera {
  SimCamera({
    required this.width,
    required this.height,
    required this.focalPx,
    required this.position,
    this.pitchDeg = 0,
  });

  final double width;
  final double height;
  final double focalPx;

  /// Camera centre (X, Y, Z) with Z < 0 (in front of the athlete plane).
  final (double, double, double) position;

  /// Downward tilt.
  final double pitchDeg;

  Vec2 project(double x, double y, [double z = 0]) {
    final (cx, cy, cz) = position;
    var dx = x - cx, dy = y - cy, dz = z - cz;
    final p = -pitchDeg * math.pi / 180;
    final cp = math.cos(p), sp = math.sin(p);
    // Pitch about the X axis (looking down).
    final ry = dy * cp - dz * sp;
    final rz = dy * sp + dz * cp;
    dy = ry;
    dz = rz;
    final u = width / 2 + focalPx * dx / dz;
    final v = height / 2 - focalPx * dy / dz;
    return Vec2(u, v);
  }

  /// Approximate pixels per metre at the athlete plane distance.
  double get pxPerMeterAtPlane => focalPx / -position.$3;
}

/// Side-view humanoid. Absolute segment angles: 0 = pointing down, π = up,
/// +π/2 = pointing in the facing direction.
class RigPose {
  RigPose({
    required this.hipX,
    required this.hipY,
    this.facing = 1,
    this.torso = math.pi,
    this.neck = 0,
    this.upperArmL = 0.15,
    this.forearmL = 0.3,
    this.upperArmR = -0.15,
    this.forearmR = 0.1,
    this.thighL = 0.1,
    this.shinL = 0,
    this.thighR = -0.1,
    this.shinR = 0,
  });

  /// Hip centre in metres (world plane Z=0).
  double hipX, hipY;
  double facing;
  double torso, neck;
  double upperArmL, forearmL, upperArmR, forearmR;
  double thighL, shinL, thighR, shinR;
}

class SideRig {
  SideRig(this.statureM);

  final double statureM;

  double get torsoLen => 0.30 * statureM;
  double get upperArmLen => 0.186 * statureM;
  double get forearmLen => 0.146 * statureM;
  double get thighLen => 0.245 * statureM;
  double get shinLen => 0.246 * statureM;
  double get ankleHeight => 0.039 * statureM;
  double get vertexAboveShoulder => 0.17 * statureM;

  /// Back of the heel behind the ankle joint (≈ quarter foot length).
  double get heelBehindAnkle => kHeelBehindAnkleRatio * statureM;

  /// Standing hip height above the floor.
  double get standingHipY => ankleHeight + shinLen + thighLen;

  /// World-space (Y up) unit direction of an absolute segment angle.
  (double, double) _dir(double angle, double facing) =>
      (facing * math.sin(angle), -math.cos(angle));

  /// World-space (metres, Y up) joint positions keyed by KP index, plus
  /// 'vertex' (-1) and 'heelL'/'heelR' (-2/-3).
  Map<int, (double, double)> joints(RigPose r) {
    (double, double) seg((double, double) from, double angle, double len) {
      final d = _dir(angle, r.facing);
      return (from.$1 + d.$1 * len, from.$2 + d.$2 * len);
    }

    final hip = (r.hipX, r.hipY);
    final shoulder = seg(hip, r.torso, torsoLen);
    final headAngle = r.torso + r.neck;
    final ear = seg(shoulder, headAngle, 0.105 * statureM);
    final eyeBase = seg(shoulder, headAngle, 0.11 * statureM);
    final eye = seg(eyeBase, headAngle - math.pi / 2, 0.035 * statureM);
    final nose = seg(seg(shoulder, headAngle, 0.10 * statureM), headAngle - math.pi / 2, 0.055 * statureM);
    final vertex = seg(shoulder, headAngle, vertexAboveShoulder);

    final elbowL = seg(shoulder, r.upperArmL, upperArmLen);
    final wristL = seg(elbowL, r.forearmL, forearmLen);
    final elbowR = seg(shoulder, r.upperArmR, upperArmLen);
    final wristR = seg(elbowR, r.forearmR, forearmLen);
    final kneeL = seg(hip, r.thighL, thighLen);
    final ankleL = seg(kneeL, r.shinL, shinLen);
    final kneeR = seg(hip, r.thighR, thighLen);
    final ankleR = seg(kneeR, r.shinR, shinLen);
    final heelL = (ankleL.$1 - r.facing * heelBehindAnkle, ankleL.$2 - ankleHeight);
    final heelR = (ankleR.$1 - r.facing * heelBehindAnkle, ankleR.$2 - ankleHeight);

    // In a side view the near (left) and far (right) sides overlap; the far
    // side is offset slightly so both remain visible on the HUD.
    final off = 0.012 * statureM * r.facing;
    (double, double) far((double, double) p) => (p.$1 - off, p.$2);

    return {
      KP.nose: nose,
      KP.leftEye: eye,
      KP.rightEye: far(eye),
      KP.leftEar: ear,
      KP.rightEar: far(ear),
      KP.leftShoulder: shoulder,
      KP.rightShoulder: far(shoulder),
      KP.leftElbow: elbowL,
      KP.rightElbow: far(elbowR),
      KP.leftWrist: wristL,
      KP.rightWrist: far(wristR),
      KP.leftHip: hip,
      KP.rightHip: far(hip),
      KP.leftKnee: kneeL,
      KP.rightKnee: far(kneeR),
      KP.leftAnkle: ankleL,
      KP.rightAnkle: far(ankleR),
      -1: vertex,
      -2: heelL,
      -3: far(heelR),
    };
  }
}

/// Seeded Gaussian noise.
class SimNoise {
  SimNoise(int seed) : _r = math.Random(seed);
  final math.Random _r;

  double gauss([double sigma = 1]) {
    final u1 = math.max(_r.nextDouble(), 1e-12);
    final u2 = _r.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2) * sigma;
  }

  double uniform(double a, double b) => a + _r.nextDouble() * (b - a);
  bool chance(double p) => _r.nextDouble() < p;
  int nextInt(int max) => _r.nextInt(max);
}

/// Projects a rig into a [PoseFrame] with realistic detector noise.
PoseFrame renderRig({
  required SideRig rig,
  required RigPose pose,
  required SimCamera cam,
  required SimNoise noise,
  required double tMs,
  required int index,
  double pixelSigma = 1.2,
  double dropoutChance = 0.01,
  Vec2? ball,
  bool visible = true,
  Map<int, (double, double)>? jointOverrides,
}) {
  if (!visible) {
    return PoseFrame(
      tMs: tMs,
      width: cam.width,
      height: cam.height,
      index: index,
      ball: ball,
      keypoints: List.filled(KP.count, Keypoint.missing),
    );
  }
  final j = rig.joints(pose);
  if (jointOverrides != null) j.addAll(jointOverrides);
  final kps = List<Keypoint>.generate(KP.count, (i) {
    final w = j[i]!;
    final p = cam.project(w.$1, w.$2);
    final dropped = noise.chance(dropoutChance);
    final isFar = i.isEven && i >= KP.rightEye; // right side is the far side
    final base = isFar ? 0.72 : 0.9;
    return Keypoint(
      Vec2(p.x + noise.gauss(pixelSigma), p.y + noise.gauss(pixelSigma)),
      dropped ? noise.uniform(0.05, 0.2) : (base + noise.gauss(0.04)).clamp(0.3, 0.99),
    );
  });
  final v = j[-1]!, hl = j[-2]!, hr = j[-3]!;
  final heel = hl.$2 <= hr.$2 ? hl : hr;
  return PoseFrame(
    tMs: tMs,
    width: cam.width,
    height: cam.height,
    index: index,
    keypoints: kps,
    ball: ball,
    silhouetteTop: cam.project(v.$1, v.$2) + Vec2(0, noise.gauss(0.6)),
    silhouetteBottom: cam.project(heel.$1, math.min(hl.$2, hr.$2)) + Vec2(0, noise.gauss(0.6)),
  );
}

double smoothstep(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double lerpD(double a, double b, double t) => a + (b - a) * t;
