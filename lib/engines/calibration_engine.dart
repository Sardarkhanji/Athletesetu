/// Module A: spatial calibration and capture-quality checks.
///
/// * Detects printed square markers (20 cm, black on white) and converts
///   pixels to centimetres via a planar homography (wall / box plane) or a
///   ground-plane homography plus a 1-D projective map along the jump line.
/// * Validates the device is level (±2°) from the accelerometer, frame rate
///   (≥30 FPS, 60/120 optimal) and resolution (≥720p).
/// * Simulation Mode: projects virtual markers through the simulator's pinhole
///   camera and synthesises accelerometer readings that settle to level, so
///   the exact same maths runs without a camera.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sensors_plus/sensors_plus.dart';

import '../core/domain/sai_test.dart';
import 'pose_types.dart';

// ---------------------------------------------------------------------------
// Linear algebra
// ---------------------------------------------------------------------------

/// Solves Ax = b (n×n) with partial pivoting. Returns null if singular.
List<double>? solveLinear(List<List<double>> a, List<double> b) {
  final n = b.length;
  final m = [for (var i = 0; i < n; i++) [...a[i], b[i]]];
  for (var col = 0; col < n; col++) {
    var pivot = col;
    for (var r = col + 1; r < n; r++) {
      if (m[r][col].abs() > m[pivot][col].abs()) pivot = r;
    }
    if (m[pivot][col].abs() < 1e-12) return null;
    final tmp = m[col];
    m[col] = m[pivot];
    m[pivot] = tmp;
    for (var r = 0; r < n; r++) {
      if (r == col) continue;
      final f = m[r][col] / m[col][col];
      if (f == 0) continue;
      for (var c = col; c <= n; c++) {
        m[r][c] -= f * m[col][c];
      }
    }
  }
  return [for (var i = 0; i < n; i++) m[i][n] / m[i][i]];
}

/// 3×3 planar homography (row-major, h[8] = 1 after normalisation).
class Homography {
  const Homography(this.h);
  final List<double> h;

  Vec2 map(Vec2 p) {
    final w = h[6] * p.x + h[7] * p.y + h[8];
    return Vec2((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w);
  }

  Homography inverse() {
    final a = h;
    final det = a[0] * (a[4] * a[8] - a[5] * a[7]) -
        a[1] * (a[3] * a[8] - a[5] * a[6]) +
        a[2] * (a[3] * a[7] - a[4] * a[6]);
    final inv = [
      (a[4] * a[8] - a[5] * a[7]) / det,
      (a[2] * a[7] - a[1] * a[8]) / det,
      (a[1] * a[5] - a[2] * a[4]) / det,
      (a[5] * a[6] - a[3] * a[8]) / det,
      (a[0] * a[8] - a[2] * a[6]) / det,
      (a[2] * a[3] - a[0] * a[5]) / det,
      (a[3] * a[7] - a[4] * a[6]) / det,
      (a[1] * a[6] - a[0] * a[7]) / det,
      (a[0] * a[4] - a[1] * a[3]) / det,
    ];
    return Homography([for (final v in inv) v / inv[8]]);
  }

  /// Least-squares DLT with Hartley normalisation (n ≥ 4 correspondences).
  static Homography? fromPoints(List<Vec2> src, List<Vec2> dst) {
    if (src.length < 4 || src.length != dst.length) return null;
    final (ns, ts) = _normalise(src);
    final (nd, td) = _normalise(dst);
    // Normal equations AᵀA h = Aᵀb for 8 unknowns (h33 = 1).
    final ata = List.generate(8, (_) => List<double>.filled(8, 0));
    final atb = List<double>.filled(8, 0);
    void addRow(List<double> row, double rhs) {
      for (var i = 0; i < 8; i++) {
        atb[i] += row[i] * rhs;
        for (var j = 0; j < 8; j++) {
          ata[i][j] += row[i] * row[j];
        }
      }
    }

    for (var i = 0; i < ns.length; i++) {
      final x = ns[i].x, y = ns[i].y, u = nd[i].x, v = nd[i].y;
      addRow([x, y, 1, 0, 0, 0, -u * x, -u * y], u);
      addRow([0, 0, 0, x, y, 1, -v * x, -v * y], v);
    }
    final sol = solveLinear(ata, atb);
    if (sol == null) return null;
    final hn = [...sol, 1.0];
    // Denormalise: H = Td⁻¹ · Hn · Ts
    final r = _mul(_mul(_invSim(td), hn), ts);
    if (r[8].abs() < 1e-12) return null;
    return Homography([for (final v in r) v / r[8]]);
  }

  /// Least-squares reflection-similarity (4 DOF: scale, rotation, translation,
  /// with the image-y-down → world-y-up flip). Used for wall/box markers: the
  /// level check guarantees a fronto-parallel plane, and with only 4 noisy
  /// corners a full 8-DOF homography lets corner noise leak into the
  /// projective terms, distorting scale far from the marker.
  ///   x' = a·x + b·y + c,   y' = b·x − a·y + d
  static Homography? similarityFromPoints(List<Vec2> src, List<Vec2> dst) {
    if (src.length < 2 || src.length != dst.length) return null;
    final ata = List.generate(4, (_) => List<double>.filled(4, 0));
    final atb = List<double>.filled(4, 0);
    void addRow(List<double> row, double rhs) {
      for (var i = 0; i < 4; i++) {
        atb[i] += row[i] * rhs;
        for (var j = 0; j < 4; j++) {
          ata[i][j] += row[i] * row[j];
        }
      }
    }

    for (var i = 0; i < src.length; i++) {
      final p = src[i], q = dst[i];
      addRow([p.x, p.y, 1, 0], q.x);
      addRow([-p.y, p.x, 0, 1], q.y);
    }
    final s = solveLinear(ata, atb);
    if (s == null) return null;
    final a = s[0], b = s[1], c = s[2], d = s[3];
    return Homography([a, b, c, b, -a, d, 0, 0, 1]);
  }

  /// Mean reprojection error (in destination units).
  double reprojectionError(List<Vec2> src, List<Vec2> dst) =>
      mean([for (var i = 0; i < src.length; i++) map(src[i]).distanceTo(dst[i])]);

  static (List<Vec2>, List<double>) _normalise(List<Vec2> pts) {
    final c = Vec2(mean(pts.map((p) => p.x)), mean(pts.map((p) => p.y)));
    final d = mean(pts.map((p) => p.distanceTo(c)));
    final s = d == 0 ? 1.0 : math.sqrt2 / d;
    return (
      [for (final p in pts) (p - c) * s],
      [s, 0, -s * c.x, 0, s, -s * c.y, 0, 0, 1],
    );
  }

  static List<double> _invSim(List<double> t) {
    final s = t[0];
    return [1 / s, 0, -t[2] / s, 0, 1 / s, -t[5] / s, 0, 0, 1];
  }

  static List<double> _mul(List<double> a, List<double> b) => [
        for (var r = 0; r < 3; r++)
          for (var c = 0; c < 3; c++)
            a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c],
      ];
}

/// 1-D projective map along an imaged straight line (the jump/throw line):
/// world = (a·t + b) / (c·t + 1), t = position along the image line.
/// Fitted from ≥3 collinear marker corners; robust even when the floor is
/// seen at a grazing angle (where a 2-D floor homography is ill-conditioned).
class LineProjectiveMap {
  LineProjectiveMap._(this.origin, this.dir, this.a, this.b, this.c);

  final Vec2 origin;
  final Vec2 dir;
  final double a, b, c;

  static LineProjectiveMap? fit(List<Vec2> imagePts, List<double> worldCm) {
    if (imagePts.length < 3) return null;
    final origin = imagePts.first;
    final dir = (imagePts.last - origin).normalized;
    final ts = [for (final p in imagePts) (p - origin).dot(dir)];
    // w(c t + 1) = a t + b  →  a t + b − c t w = w
    final ata = List.generate(3, (_) => List<double>.filled(3, 0));
    final atb = List<double>.filled(3, 0);
    for (var i = 0; i < ts.length; i++) {
      final row = [ts[i], 1.0, -ts[i] * worldCm[i]];
      for (var r = 0; r < 3; r++) {
        atb[r] += row[r] * worldCm[i];
        for (var k = 0; k < 3; k++) {
          ata[r][k] += row[r] * row[k];
        }
      }
    }
    final s = solveLinear(ata, atb);
    if (s == null) return null;
    return LineProjectiveMap._(origin, dir, s[0], s[1], s[2]);
  }

  /// World coordinate (cm along the line) of an image point (projected onto the line).
  double worldAt(Vec2 p) {
    final t = (p - origin).dot(dir);
    return (a * t + b) / (c * t + 1);
  }

  /// Image point on the line for a given world coordinate.
  Vec2 imageAt(double w) {
    // w(c t + 1) = a t + b → t = (b − w) / (w c − a)
    final t = (b - w) / (w * c - a);
    return origin + dir * t;
  }

  /// Image-space y of the line at a given x (for "is the foot on the floor").
  double yAtX(double x) {
    if (dir.x.abs() < 1e-9) return origin.y;
    return origin.y + (x - origin.x) * dir.y / dir.x;
  }
}

// ---------------------------------------------------------------------------
// Capture quality
// ---------------------------------------------------------------------------

class LevelReading {
  const LevelReading(this.rollDeg, this.pitchDeg);
  final double rollDeg;
  final double pitchDeg;

  static const tolerance = 2.0;

  /// Wall-plane tests need the phone plumb (roll and pitch); floor tests allow a downward pitch.
  bool isLevel({required bool requirePitch}) =>
      rollDeg.abs() <= tolerance && (!requirePitch || pitchDeg.abs() <= tolerance);

  double worstDeg({required bool requirePitch}) =>
      requirePitch ? math.max(rollDeg.abs(), pitchDeg.abs()) : rollDeg.abs();

  /// Phone upright in portrait: gravity along +y. Roll = rotation in the screen plane.
  static LevelReading fromAccelerometer(double x, double y, double z) {
    final roll = math.atan2(x, y) * 180 / math.pi;
    final pitch = math.atan2(z, math.sqrt(x * x + y * y)) * 180 / math.pi;
    return LevelReading(roll, pitch);
  }
}

/// Low-pass-filtered tilt from the accelerometer (or a simulated settle).
class LevelMonitor {
  LevelMonitor({required this.simulated, int seed = 7}) : _noise = SimNoise(seed);

  final bool simulated;
  final SimNoise _noise;
  StreamSubscription<AccelerometerEvent>? _sub;
  Timer? _simTimer;
  final _controller = StreamController<LevelReading>.broadcast();
  double _fx = 0, _fy = 9.8, _fz = 0;
  LevelReading _last = const LevelReading(0, 0);

  Stream<LevelReading> get stream => _controller.stream;
  LevelReading get last => _last;

  void start() {
    if (simulated) {
      // Starts ~4° off and settles to within ±0.5° over ~2.5 s, like a tripod being adjusted.
      final started = DateTime.now();
      _simTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        final t = DateTime.now().difference(started).inMilliseconds / 1000;
        final k = math.exp(-t / 0.9);
        _emit(LevelReading(4.2 * k + _noise.gauss(0.15), -3.1 * k + _noise.gauss(0.15)));
      });
      return;
    }
    _sub = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(
      (e) {
        const a = 0.15; // low-pass factor
        _fx += a * (e.x - _fx);
        _fy += a * (e.y - _fy);
        _fz += a * (e.z - _fz);
        _emit(LevelReading.fromAccelerometer(_fx, _fy, _fz));
      },
      onError: (_) {}, // No accelerometer: leave the last reading.
      cancelOnError: false,
    );
  }

  void _emit(LevelReading r) {
    _last = r;
    if (!_controller.isClosed) _controller.add(r);
  }

  Future<void> dispose() async {
    _simTimer?.cancel();
    await _sub?.cancel();
    await _controller.close();
  }
}

/// Rolling frames-per-second estimate from frame timestamps.
class FrameRateMeter {
  final _times = <double>[];

  void add(double tMs) {
    _times.add(tMs);
    while (_times.length > 2 && _times.last - _times.first > 1000) {
      _times.removeAt(0);
    }
  }

  double get fps {
    if (_times.length < 2) return 0;
    final span = _times.last - _times.first;
    return span <= 0 ? 0 : (_times.length - 1) * 1000 / span;
  }

  void reset() => _times.clear();
}

class CaptureQuality {
  const CaptureQuality({required this.fps, required this.width, required this.height});
  final double fps;
  final double width;
  final double height;

  bool get fpsOk => fps >= 29; // allow camera jitter around 30
  bool get fpsOptimal => fps >= 59;
  bool get resolutionOk => math.min(width, height) >= 720;

  String get resolutionLabel => '${math.min(width, height).round()}p';
}

// ---------------------------------------------------------------------------
// Marker detection (pure Dart, grayscale)
// ---------------------------------------------------------------------------

/// Otsu's threshold over an 8-bit buffer.
int otsuThreshold(Uint8List gray) {
  final hist = List<int>.filled(256, 0);
  for (final v in gray) {
    hist[v]++;
  }
  final total = gray.length;
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumB = 0.0, wB = 0, best = 0.0, threshold = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      threshold = t;
    }
  }
  return threshold;
}

/// Finds dark, square-ish blobs and returns their 4 corners (TL, TR, BR, BL),
/// sorted left-to-right. Coordinates are in the buffer's pixel space.
List<List<Vec2>> detectSquareMarkers(Uint8List gray, int w, int h, {int maxMarkers = 2}) {
  final thr = otsuThreshold(gray);
  final visited = Uint8List(w * h);
  final minArea = (w * h * 0.0004).round();
  final maxArea = (w * h * 0.25).round();
  final found = <(int, List<Vec2>)>[];
  final stack = <int>[];

  for (var start = 0; start < w * h; start++) {
    if (visited[start] == 1 || gray[start] > thr) continue;
    // Flood-fill a dark component.
    var area = 0;
    var tl = start, tr = start, br = start, bl = start;
    var sTl = 1 << 30, sBr = -1, dTr = -(1 << 30), dBl = 1 << 30;
    var minX = w, maxX = 0, minY = h, maxY = 0;
    stack
      ..clear()
      ..add(start);
    visited[start] = 1;
    while (stack.isNotEmpty) {
      final idx = stack.removeLast();
      final x = idx % w, y = idx ~/ w;
      area++;
      final s = x + y, d = x - y;
      if (s < sTl) {
        sTl = s;
        tl = idx;
      }
      if (s > sBr) {
        sBr = s;
        br = idx;
      }
      if (d > dTr) {
        dTr = d;
        tr = idx;
      }
      if (d < dBl) {
        dBl = d;
        bl = idx;
      }
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      for (final n in [idx - 1, idx + 1, idx - w, idx + w]) {
        if (n < 0 || n >= w * h) continue;
        if ((n % w - x).abs() > 1) continue; // row wrap
        if (visited[n] == 0 && gray[n] <= thr) {
          visited[n] = 1;
          stack.add(n);
        }
      }
    }
    if (area < minArea || area > maxArea) continue;
    // Touching the border → likely background, not a marker.
    if (minX == 0 || minY == 0 || maxX == w - 1 || maxY == h - 1) continue;
    Vec2 pt(int i) => Vec2((i % w).toDouble(), (i ~/ w).toDouble());
    final quad = [pt(tl), pt(tr), pt(br), pt(bl)];
    final quadArea = _polygonArea(quad);
    if (quadArea <= 0) continue;
    final fill = area / quadArea;
    final sideA = quad[0].distanceTo(quad[1]), sideB = quad[1].distanceTo(quad[2]);
    final aspect = sideA / math.max(sideB, 1);
    // Squares viewed obliquely become trapezoids: accept moderate aspect.
    if (fill < 0.82 || fill > 1.2 || aspect < 0.25 || aspect > 4) continue;
    found.add((area, quad));
  }
  found.sort((a, b) => b.$1.compareTo(a.$1));
  final top = found.take(maxMarkers).map((e) => e.$2).toList()
    ..sort((a, b) => a[0].x.compareTo(b[0].x));
  return top;
}

double _polygonArea(List<Vec2> p) {
  var a = 0.0;
  for (var i = 0; i < p.length; i++) {
    a += p[i].cross(p[(i + 1) % p.length]);
  }
  return a.abs() / 2;
}

// ---------------------------------------------------------------------------
// Calibration result + engine
// ---------------------------------------------------------------------------

class CalibrationResult {
  const CalibrationResult({
    required this.kind,
    required this.imageWidth,
    required this.imageHeight,
    required this.pixelsPerCm,
    required this.confidence,
    this.planeHomography,
    this.lineMap,
    this.markers = const [],
    this.gateLinesX = const [],
    this.level,
    this.quality,
    this.simulated = false,
    this.reprojectionErrorCm = 0,
  });

  final CalibrationKind kind;
  final double imageWidth;
  final double imageHeight;

  /// Mean scale at the marker plane.
  final double pixelsPerCm;

  /// Image → plane (cm). Wall/box: (x right, y UP). Floor: (X along jump, Z depth).
  final Homography? planeHomography;

  /// Image → cm along the jump/throw line (floor tests).
  final LineProjectiveMap? lineMap;
  final List<List<Vec2>> markers;

  /// Vertical virtual gate lines (finish / turn) in image x pixels.
  final List<double> gateLinesX;
  final LevelReading? level;
  final CaptureQuality? quality;
  final bool simulated;
  final double reprojectionErrorCm;

  /// 0–100.
  final double confidence;

  Vec2 toPlaneCm(Vec2 px) => planeHomography?.map(px) ?? Vec2(px.x / pixelsPerCm, -px.y / pixelsPerCm);

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'pixelsPerCm': double.parse(pixelsPerCm.toStringAsFixed(4)),
        'confidence': confidence.round(),
        'reprojErrCm': double.parse(reprojectionErrorCm.toStringAsFixed(3)),
        'gateLinesX': gateLinesX,
        'simulated': simulated,
        if (level != null) 'rollDeg': double.parse(level!.rollDeg.toStringAsFixed(2)),
        if (quality != null) 'fps': quality!.fps.round(),
      };
}

class CalibrationException implements Exception {
  CalibrationException(this.messageKey);
  final String messageKey;
  @override
  String toString() => messageKey;
}

class CalibrationEngine {
  const CalibrationEngine({this.markerSizeCm = 20, this.farMarkerOffsetCm = 300});

  /// Printed marker edge length.
  final double markerSizeCm;

  /// Distance from the take-off marker to the far floor marker.
  final double farMarkerOffsetCm;

  /// Marker corner world coordinates (TL, TR, BR, BL) in cm.
  List<Vec2> _planeCorners(double x0) => [
        Vec2(x0, markerSizeCm),
        Vec2(x0 + markerSizeCm, markerSizeCm),
        Vec2(x0 + markerSizeCm, 0),
        Vec2(x0, 0),
      ];

  /// Builds a calibration from detected marker quads.
  CalibrationResult fromMarkers({
    required CalibrationKind kind,
    required List<List<Vec2>> markers,
    required double imageWidth,
    required double imageHeight,
    LevelReading? level,
    CaptureQuality? quality,
    bool simulated = false,
  }) {
    final needed = kind == CalibrationKind.floorMarkers ? 2 : 1;
    if (markers.length < needed) throw CalibrationException('cal_no_marker');

    final src = <Vec2>[], dst = <Vec2>[];
    for (var i = 0; i < needed; i++) {
      src.addAll(markers[i]);
      dst.addAll(_planeCorners(i == 0 ? 0 : farMarkerOffsetCm));
    }
    final hom = kind == CalibrationKind.floorMarkers
        ? Homography.fromPoints(src, dst)
        : Homography.similarityFromPoints(src, dst);
    if (hom == null) throw CalibrationException('cal_no_marker');
    var err = hom.reprojectionError(src, dst);

    // Mean side length of the first marker in px → px/cm.
    final q = markers.first;
    final side = mean([
      for (var i = 0; i < 4; i++) q[i].distanceTo(q[(i + 1) % 4]),
    ]);
    var ppc = side / markerSizeCm;

    LineProjectiveMap? line;
    if (kind == CalibrationKind.floorMarkers) {
      // Bottom (near) edges of both markers lie on the jump line (Z = 0).
      final a = markers[0], b = markers[1];
      line = LineProjectiveMap.fit(
        [a[3], a[2], b[3], b[2]],
        [0, markerSizeCm, farMarkerOffsetCm, farMarkerOffsetCm + markerSizeCm],
      );
      if (line == null) throw CalibrationException('cal_no_marker');
      ppc = (b[3].distanceTo(a[3])) / farMarkerOffsetCm;
      // Distances are read through the 1-D line map, not the (grazing-angle,
      // ill-conditioned) 2-D floor homography, so score its residual instead.
      final lineErr = mean([
        (line.worldAt(a[3]) - 0).abs(),
        (line.worldAt(a[2]) - markerSizeCm).abs(),
        (line.worldAt(b[3]) - farMarkerOffsetCm).abs(),
        (line.worldAt(b[2]) - farMarkerOffsetCm - markerSizeCm).abs(),
      ]);
      err = lineErr;
    }

    final levelPenalty = level == null
        ? 0.0
        : math.max(0.0, level.worstDeg(requirePitch: kind != CalibrationKind.floorMarkers) - 1) * 6;
    final fpsPenalty = quality == null || quality.fpsOk ? 0.0 : 15.0;
    final conf = (100 - err * 25 - levelPenalty - fpsPenalty).clamp(20.0, 100.0);

    return CalibrationResult(
      kind: kind,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      pixelsPerCm: ppc,
      planeHomography: hom,
      lineMap: line,
      markers: markers.take(needed).toList(),
      level: level,
      quality: quality,
      simulated: simulated,
      reprojectionErrorCm: err,
      confidence: conf,
    );
  }

  /// Detects markers in a grayscale frame (downsampled), then calibrates.
  /// [scale] maps buffer pixels back to image pixels.
  CalibrationResult fromGrayFrame({
    required CalibrationKind kind,
    required Uint8List gray,
    required int bufferWidth,
    required int bufferHeight,
    required double scale,
    required double imageWidth,
    required double imageHeight,
    LevelReading? level,
    CaptureQuality? quality,
  }) {
    final quads = detectSquareMarkers(gray, bufferWidth, bufferHeight,
        maxMarkers: kind == CalibrationKind.floorMarkers ? 2 : 1);
    final scaled = [for (final q in quads) [for (final p in q) p * scale]];
    return fromMarkers(
      kind: kind,
      markers: scaled,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      level: level,
      quality: quality,
    );
  }

  /// Timing-gate calibration: virtual vertical line(s), no marker needed.
  CalibrationResult forGates({
    required List<double> linesX,
    required double imageWidth,
    required double imageHeight,
    LevelReading? level,
    CaptureQuality? quality,
    bool simulated = false,
  }) =>
      CalibrationResult(
        kind: CalibrationKind.finishLine,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        pixelsPerCm: 1,
        gateLinesX: linesX,
        level: level,
        quality: quality,
        simulated: simulated,
        confidence: quality == null || quality.fpsOk ? 95 : 70,
      );

  /// No spatial calibration (sit-ups, weight).
  CalibrationResult none({required double imageWidth, required double imageHeight, bool simulated = false}) =>
      CalibrationResult(
        kind: CalibrationKind.none,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        pixelsPerCm: 1,
        simulated: simulated,
        confidence: 100,
      );
}

// ---------------------------------------------------------------------------
// Simulation
// ---------------------------------------------------------------------------

/// Projects virtual printed markers through a simulator's camera, adding
/// sub-pixel corner noise, then runs the real calibration maths on them.
class CalibrationSimulator {
  CalibrationSimulator({int seed = 11}) : _noise = SimNoise(seed);
  final SimNoise _noise;

  /// [wallZ] = depth of the wall/box plane (0 = athlete plane).
  List<List<Vec2>> markers(SimCamera cam, CalibrationKind kind,
      {double markerSizeM = 0.20, double farOffsetM = 3.0, double wallX = -0.6, double wallBaseY = 1.0}) {
    Vec2 n(Vec2 p) => Vec2(p.x + _noise.gauss(0.35), p.y + _noise.gauss(0.35));
    switch (kind) {
      case CalibrationKind.wallMarker:
      case CalibrationKind.boxScale:
        // Vertical plane at Z = 0: TL, TR, BR, BL.
        final x0 = wallX, y0 = wallBaseY, s = markerSizeM;
        return [
          [
            n(cam.project(x0, y0 + s)),
            n(cam.project(x0 + s, y0 + s)),
            n(cam.project(x0 + s, y0)),
            n(cam.project(x0, y0)),
          ]
        ];
      case CalibrationKind.floorMarkers:
        // Floor plane Y = 0: near edge at Z = 0 (the jump line), far edge at Z = +s.
        List<Vec2> quad(double x0) => [
              n(cam.project(x0, 0, markerSizeM)),
              n(cam.project(x0 + markerSizeM, 0, markerSizeM)),
              n(cam.project(x0 + markerSizeM, 0, 0)),
              n(cam.project(x0, 0, 0)),
            ];
        return [quad(0), quad(farOffsetM)];
      case CalibrationKind.finishLine:
      case CalibrationKind.none:
        return const [];
    }
  }

  CaptureQuality quality(FrameSimulator sim) =>
      CaptureQuality(fps: sim.fps, width: sim.width, height: sim.height);
}
