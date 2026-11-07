/// Module E: Assisted measurement — Weight (scale OCR + BMI) and Medicine Ball Throw.
///
/// * Weight (±0.1 kg): the assessor photographs the digital scale; a pure-Dart
///   seven-segment decoder (Otsu threshold → glyph segmentation → 7-region
///   sampling) reads the display fully offline. BMI = kg / m².
/// * Medicine ball (±5 cm): the ball track's first ground contact is proposed
///   as the landing frame; the assessor scrubs frames in slow motion and taps
///   the exact first-bounce point, which is mapped through the floor
///   calibration to centimetres.
///
/// Simulation Mode: [ScaleDisplaySimulator] renders a realistic LCD photo
/// (illumination gradient, sensor noise, ghost segments, blur) that the real
/// decoder must read; [MedicineBallSimulator] throws a projectile with bounce.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/domain/sai_test.dart';
import 'calibration_engine.dart';
import 'pose_types.dart';

class GrayImage {
  const GrayImage(this.width, this.height, this.data);
  final int width;
  final int height;
  final Uint8List data;

  int at(int x, int y) => data[y * width + x];

  GrayImage crop(int x0, int y0, int w, int h) {
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      out.setRange(y * w, y * w + w, data, (y0 + y) * width + x0);
    }
    return GrayImage(w, h, out);
  }
}

/// Region of interest in normalised (0..1) image coordinates.
class NormRect {
  const NormRect(this.left, this.top, this.width, this.height);
  final double left, top, width, height;
  static const full = NormRect(0, 0, 1, 1);
}

class OcrDigit {
  const OcrDigit(this.char, this.confidence, this.x0, this.x1, this.y0, this.y1);
  final String char;
  final double confidence;
  final int x0, x1, y0, y1;
}

class OcrReading {
  const OcrReading({required this.text, required this.value, required this.confidence, required this.digits});
  final String text;
  final double? value;

  /// 0–100.
  final double confidence;
  final List<OcrDigit> digits;
}

// ---------------------------------------------------------------------------
// Seven-segment decoder
// ---------------------------------------------------------------------------

class SevenSegmentDecoder {
  const SevenSegmentDecoder();

  // Segment bit order: a b c d e f g
  static const _table = <String, String>{
    '1111110': '0', '0110000': '1', '1101101': '2', '1111001': '3', '0110011': '4',
    '1011011': '5', '1011111': '6', '1110000': '7', '1111111': '8', '1111011': '9',
    '0011111': '6', '1110011': '9', '1110010': '7',
  };

  OcrReading decode(GrayImage img, {NormRect roi = NormRect.full}) {
    final x0 = (roi.left * img.width).round().clamp(0, img.width - 2);
    final y0 = (roi.top * img.height).round().clamp(0, img.height - 2);
    final w = (roi.width * img.width).round().clamp(2, img.width - x0);
    final h = (roi.height * img.height).round().clamp(2, img.height - y0);
    final g = img.crop(x0, y0, w, h);

    final thr = otsuThreshold(g.data);
    var dark = 0;
    for (final v in g.data) {
      if (v <= thr) dark++;
    }
    final darkIsInk = dark <= g.data.length / 2; // segments are the minority
    final fg = Uint8List(w * h);
    for (var i = 0; i < fg.length; i++) {
      final isDark = g.data[i] <= thr;
      fg[i] = (isDark == darkIsInk) ? 1 : 0;
    }

    // Row projection → main text band.
    final rows = List<int>.generate(h, (y) {
      var c = 0;
      for (var x = 0; x < w; x++) {
        c += fg[y * w + x];
      }
      return c;
    });
    final rowOn = [for (final c in rows) c > math.max(2, w * 0.015)];
    final (bandTop, bandBot) = _longestRun(rowOn, maxGap: (h * 0.03).ceil());
    if (bandBot - bandTop < 8) {
      return const OcrReading(text: '', value: null, confidence: 0, digits: []);
    }
    final bandH = bandBot - bandTop + 1;

    // Column projection inside the band → glyph runs.
    final colOn = List<bool>.generate(w, (x) {
      var c = 0;
      for (var y = bandTop; y <= bandBot; y++) {
        c += fg[y * w + x];
      }
      return c >= 2;
    });
    final runs = _runs(colOn, mergeGap: (bandH * 0.06).ceil());

    final digits = <OcrDigit>[];
    for (final (cx0, cx1) in runs) {
      var gy0 = bandBot, gy1 = bandTop;
      for (var y = bandTop; y <= bandBot; y++) {
        for (var x = cx0; x <= cx1; x++) {
          if (fg[y * w + x] == 1) {
            if (y < gy0) gy0 = y;
            if (y > gy1) gy1 = y;
          }
        }
      }
      final gw = cx1 - cx0 + 1, gh = gy1 - gy0 + 1;
      if (gh < bandH * 0.25 && gy0 > bandTop + bandH * 0.6) {
        digits.add(OcrDigit('.', 0.95, cx0, cx1, gy0, gy1));
        continue;
      }
      if (gh < bandH * 0.5) continue; // speck / unit label
      if (gw < bandH * 0.32) {
        digits.add(OcrDigit('1', 0.9, cx0, cx1, gy0, gy1));
        continue;
      }
      final (char, conf) = _classify(fg, w, cx0, cx1, gy0, gy1);
      if (char != null) digits.add(OcrDigit(char, conf, cx0, cx1, gy0, gy1));
    }

    final text = digits.map((d) => d.char).join();
    final cleaned = text.replaceAll(RegExp(r'^\.+|\.+$'), '');
    final value = double.tryParse(cleaned);
    final conf = digits.isEmpty ? 0.0 : mean(digits.map((d) => d.confidence)) * 100;
    return OcrReading(text: cleaned, value: value, confidence: value == null ? 0 : conf, digits: digits);
  }

  (String?, double) _classify(Uint8List fg, int w, int x0, int x1, int y0, int y1) {
    final gw = x1 - x0 + 1, gh = y1 - y0 + 1;
    double frac(double fx0, double fx1, double fy0, double fy1) {
      final ax = (x0 + fx0 * gw).round(), bx = (x0 + fx1 * gw).round();
      final ay = (y0 + fy0 * gh).round(), by = (y0 + fy1 * gh).round();
      var on = 0, n = 0;
      for (var y = ay; y <= by; y++) {
        for (var x = ax; x <= bx; x++) {
          on += fg[y * w + x];
          n++;
        }
      }
      return n == 0 ? 0 : on / n;
    }

    final f = [
      frac(0.3, 0.7, 0.0, 0.1), // a
      frac(0.8, 1.0, 0.15, 0.4), // b
      frac(0.8, 1.0, 0.6, 0.85), // c
      frac(0.3, 0.7, 0.9, 1.0), // d
      frac(0.0, 0.2, 0.6, 0.85), // e
      frac(0.0, 0.2, 0.15, 0.4), // f
      frac(0.3, 0.7, 0.45, 0.55), // g
    ];
    const on = 0.35;
    final bits = f.map((v) => v > on ? '1' : '0').join();
    final margin = mean(f.map((v) => ((v - on).abs() / on).clamp(0.0, 1.0)));
    final exact = _table[bits];
    if (exact != null) return (exact, 0.6 + 0.4 * margin);
    // Nearest pattern by Hamming distance (one flipped segment).
    String? best;
    var bestD = 99;
    _table.forEach((k, v) {
      var d = 0;
      for (var i = 0; i < 7; i++) {
        if (k[i] != bits[i]) d++;
      }
      if (d < bestD) {
        bestD = d;
        best = v;
      }
    });
    return bestD <= 1 ? (best, 0.45 * (0.6 + 0.4 * margin)) : (null, 0);
  }

  static (int, int) _longestRun(List<bool> on, {required int maxGap}) {
    var bestA = 0, bestB = -1, a = -1, gap = 0;
    for (var i = 0; i <= on.length; i++) {
      final v = i < on.length && on[i];
      if (v) {
        if (a < 0) a = i;
        gap = 0;
      } else if (a >= 0) {
        gap++;
        if (gap > maxGap || i == on.length) {
          final b = i - gap;
          if (b - a > bestB - bestA) {
            bestA = a;
            bestB = b;
          }
          a = -1;
          gap = 0;
        }
      }
    }
    return (bestA, bestB);
  }

  static List<(int, int)> _runs(List<bool> on, {required int mergeGap}) {
    final raw = <(int, int)>[];
    var a = -1;
    for (var i = 0; i <= on.length; i++) {
      final v = i < on.length && on[i];
      if (v && a < 0) a = i;
      if (!v && a >= 0) {
        raw.add((a, i - 1));
        a = -1;
      }
    }
    final merged = <(int, int)>[];
    for (final r in raw) {
      if (merged.isNotEmpty && r.$1 - merged.last.$2 - 1 <= mergeGap) {
        merged[merged.length - 1] = (merged.last.$1, r.$2);
      } else {
        merged.add(r);
      }
    }
    return merged;
  }
}

// ---------------------------------------------------------------------------
// Weight + BMI
// ---------------------------------------------------------------------------

double bmi(double kg, double heightCm) => kg / math.pow(heightCm / 100, 2);

class WeightOcrEngine {
  const WeightOcrEngine({this.decoder = const SevenSegmentDecoder()});
  final SevenSegmentDecoder decoder;

  AttemptOutcome read(GrayImage img, {NormRect roi = NormRect.full, double? heightCm, bool simulated = false}) {
    final r = decoder.decode(img, roi: roi);
    final v = r.value;
    final plausible = v != null && v >= 8 && v <= 200;
    final value = plausible ? double.parse(v.toStringAsFixed(1)) : null;
    return AttemptOutcome(
      test: SaiTest.weight,
      value: value,
      confidence: plausible ? r.confidence.clamp(0, 99) : 0,
      metadata: {
        'ocrText': r.text,
        'digits': r.digits.length,
        if (value != null && heightCm != null) 'bmi': double.parse(bmi(value, heightCm).toStringAsFixed(1)),
        'heightCm': ?heightCm,
        'simulated': simulated,
      },
    );
  }
}

/// Renders a photographed LCD scale display reading [kg] ("XX.X").
class ScaleDisplaySimulator {
  ScaleDisplaySimulator({int seed = 21}) : _noise = SimNoise(seed);
  final SimNoise _noise;

  static const width = 420, height = 200;

  /// Returns the image plus the normalised display ROI.
  (GrayImage, NormRect) render(double kg) {
    final img = Float64List(width * height);
    final gx = _noise.uniform(-25, 25), gy = _noise.uniform(-15, 15);
    // Bezel + LCD window with an illumination gradient.
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final inLcd = x > 30 && x < width - 30 && y > 30 && y < height - 30;
        img[y * width + x] = inLcd
            ? 178 + gx * (x / width - 0.5) + gy * (y / height - 0.5)
            : 60 + 10 * math.sin(x / 9);
      }
    }
    final text = kg.toStringAsFixed(1).padLeft(4, ' ');
    const dw = 64, dh = 104, th = 12, gap = 2;
    var cx = 70;
    const cy = 48;
    void rect(int x0, int y0, int x1, int y1, double v) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          if (x >= 0 && x < width && y >= 0 && y < height) img[y * width + x] = v;
        }
      }
    }

    const segs = 'abcdefg';
    const patterns = {
      '0': 'abcdef', '1': 'bc', '2': 'abdeg', '3': 'abcdg', '4': 'bcfg',
      '5': 'acdfg', '6': 'acdefg', '7': 'abc', '8': 'abcdefg', '9': 'abcdfg',
    };
    for (final ch in text.split('')) {
      if (ch == '.') {
        rect(cx + 2, cy + dh - th, cx + 2 + th, cy + dh, 48);
        cx += 22;
        continue;
      }
      final lit = patterns[ch] ?? '';
      for (final s in segs.split('')) {
        final ink = lit.contains(s) ? 45 + _noise.gauss(4) : 163.0; // unlit = ghost segment
        switch (s) {
          case 'a':
            rect(cx + th ~/ 2 + gap, cy, cx + dw - th ~/ 2 - gap, cy + th, ink);
          case 'b':
            rect(cx + dw - th, cy + th ~/ 2 + gap, cx + dw, cy + dh ~/ 2 - gap, ink);
          case 'c':
            rect(cx + dw - th, cy + dh ~/ 2 + gap, cx + dw, cy + dh - th ~/ 2 - gap, ink);
          case 'd':
            rect(cx + th ~/ 2 + gap, cy + dh - th, cx + dw - th ~/ 2 - gap, cy + dh, ink);
          case 'e':
            rect(cx, cy + dh ~/ 2 + gap, cx + th, cy + dh - th ~/ 2 - gap, ink);
          case 'f':
            rect(cx, cy + th ~/ 2 + gap, cx + th, cy + dh ~/ 2 - gap, ink);
          case 'g':
            rect(cx + th ~/ 2 + gap, cy + dh ~/ 2 - th ~/ 2, cx + dw - th ~/ 2 - gap, cy + dh ~/ 2 + th ~/ 2, ink);
        }
      }
      cx += dw + 18;
    }
    // "kg" unit label (small, ignored by the decoder's height filter).
    rect(width - 70, cy + dh - 26, width - 62, cy + dh, 70);
    rect(width - 56, cy + dh - 18, width - 44, cy + dh, 70);
    // 3×3 box blur + sensor noise.
    final out = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var s = 0.0, n = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx, yy = y + dy;
            if (xx >= 0 && xx < width && yy >= 0 && yy < height) {
              s += img[yy * width + xx];
              n++;
            }
          }
        }
        out[y * width + x] = (s / n + _noise.gauss(5)).round().clamp(0, 255);
      }
    }
    return (GrayImage(width, height, out), const NormRect(0.08, 0.16, 0.84, 0.68));
  }
}

// ---------------------------------------------------------------------------
// Medicine ball throw
// ---------------------------------------------------------------------------

enum _MbPhase { waiting, flight, landed, done }

class BallSample {
  const BallSample(this.index, this.tMs, this.p);
  final int index;
  final double tMs;
  final Vec2 p;
}

class MedicineBallSession implements MeasurementSession {
  MedicineBallSession(this.cal);

  final CalibrationResult cal;

  @override
  SaiTest get test => SaiTest.medicineBall;

  LineProjectiveMap get _line => cal.lineMap!;
  _MbPhase _phase = _MbPhase.waiting;
  final track = <BallSample>[];

  /// Every frame of the attempt, for the slow-motion scrubber.
  final frames = <PoseFrame>[];
  BallSample? _start;
  int? proposedIndex;
  double? _proposedCm;
  double _fitResidualPx = 0;
  double? _landedAtMs;

  @override
  bool get isComplete => _phase == _MbPhase.done;

  double distanceCmAt(Vec2 px) => _line.worldAt(Vec2(px.x, _line.yAtX(px.x)));

  /// Floor contact point (image) directly below a ball centre.
  Vec2 contactPoint(Vec2 ball) => Vec2(ball.x, _line.yAtX(ball.x));

  @override
  EngineSnapshot process(PoseFrame f) {
    if (frames.length < 2400) frames.add(f);
    final b = f.ball;
    if (b != null && !isComplete) {
      final s = BallSample(frames.length - 1, f.tMs, b);
      track.add(s);
      switch (_phase) {
        case _MbPhase.waiting:
          // Release: ball rising and moving away from the thrower quickly.
          if (track.length >= 3) {
            final p0 = track[track.length - 3].p;
            final v = b - p0;
            if (v.length > cal.pixelsPerCm * 6 && v.y < 0) {
              _start = track[track.length - 3];
              _phase = _MbPhase.flight;
            }
          }
        case _MbPhase.flight:
          // First contact: vertical motion reverses (down → up) near the floor.
          if (track.length >= 3) {
            final a = track[track.length - 3], m = track[track.length - 2];
            final down = m.p.y - a.p.y, up = b.y - m.p.y;
            final nearFloor = (_line.yAtX(m.p.x) - m.p.y) < cal.pixelsPerCm * 25;
            if (down > 0 && up <= 0 && nearFloor) {
              proposedIndex = m.index;
              _proposedCm = distanceCmAt(_refineContact(m) ?? m.p);
              _fitResidualPx = _parabolaResidual();
              _landedAtMs = f.tMs;
              _phase = _MbPhase.landed;
            }
          }
        case _MbPhase.landed:
          if (f.tMs - _landedAtMs! > 600) _phase = _MbPhase.done;
        case _MbPhase.done:
          break;
      }
    }
    final pts = _start == null ? <Vec2>[] : track.where((s) => s.index >= _start!.index).map((s) => s.p).toList();
    return EngineSnapshot(
      phaseKey: switch (_phase) {
        _MbPhase.waiting => 'phase_throwing',
        _MbPhase.flight => 'phase_ball_flight',
        _MbPhase.landed => 'phase_ball_landed',
        _MbPhase.done => 'phase_finished',
      },
      primary: _proposedCm?.toStringAsFixed(0),
      primaryLabelKey: 'units_cm',
      overlay: [
        HudLine(_line.imageAt(0) + const Vec2(0, -40), _line.imageAt(0) + const Vec2(0, 20), tone: HudTone.warning, width: 3, label: '0'),
        for (var m = 100; m <= 700; m += 100)
          HudLine(_line.imageAt(m.toDouble()) + const Vec2(0, -8), _line.imageAt(m.toDouble()) + const Vec2(0, 8), tone: HudTone.neutral, label: '${m ~/ 100}m'),
        if (pts.length > 1) HudPath(pts, tone: HudTone.warning),
        if (b != null) HudPoint(b, tone: HudTone.primary, radius: 10),
        if (proposedIndex != null) HudPoint(contactPoint(frames[proposedIndex!].ball!), tone: HudTone.pass, radius: 8),
      ],
      complete: isComplete,
    );
  }

  /// Sub-frame contact: fit x(t) linear and y(t) quadratic to the last flight
  /// samples and solve for the instant the ball's bottom meets the floor line.
  Vec2? _refineContact(BallSample lowest) {
    final pts = track.where((s) => _start != null && s.index > _start!.index && s.index <= lowest.index).toList();
    if (pts.length < 6) return null;
    final recent = pts.sublist(math.max(0, pts.length - 14), pts.length - 1); // pre-contact only
    if (recent.length < 5) return null;
    final t0 = recent.first.tMs;
    final ts = [for (final s in recent) (s.tMs - t0) / 1000];
    List<double>? fit(List<double> ys, int degree) {
      final n = degree + 1;
      final ata = List.generate(n, (_) => List<double>.filled(n, 0));
      final atb = List<double>.filled(n, 0);
      for (var i = 0; i < ts.length; i++) {
        final row = [for (var k = degree; k >= 0; k--) math.pow(ts[i], k).toDouble()];
        for (var r = 0; r < n; r++) {
          atb[r] += row[r] * ys[i];
          for (var c = 0; c < n; c++) {
            ata[r][c] += row[r] * row[c];
          }
        }
      }
      return solveLinear(ata, atb);
    }

    final fx = fit([for (final s in recent) s.p.x], 1);
    final fy = fit([for (final s in recent) s.p.y], 2);
    if (fx == null || fy == null) return null;
    final rPx = _localPpc(lowest.p.x) * ballRadiusCm;
    // Search forward (≤ 2 frame intervals past the lowest sample) for y(t) = floorY(x(t)) − r.
    final tEnd = (lowest.tMs - t0) / 1000 + 0.04;
    Vec2 at(double t) => Vec2(fx[0] * t + fx[1], fy[0] * t * t + fy[1] * t + fy[2]);
    double gap(double t) {
      final p = at(t);
      return (_line.yAtX(p.x) - rPx) - p.y;
    }

    var a = ts.last, b = tEnd;
    if (gap(a) < 0 || gap(b) > 0) return null;
    for (var i = 0; i < 40; i++) {
      final mid = (a + b) / 2;
      if (gap(mid) > 0) {
        a = mid;
      } else {
        b = mid;
      }
    }
    return at((a + b) / 2);
  }

  /// Medicine ball radius (≈ 19–20 cm diameter for 1–2 kg balls).
  static const ballRadiusCm = 10.0;

  double _localPpc(double x) {
    final w = distanceCmAt(Vec2(x, _line.yAtX(x)));
    return _line.imageAt(w + 10).distanceTo(_line.imageAt(w)) / 10;
  }

  /// RMS residual of a parabola fitted to the pre-contact flight (track quality).
  double _parabolaResidual() {
    final all = track.where((s) => _start != null && s.index > _start!.index && s.index < (proposedIndex ?? 0)).toList();
    // Same pre-contact window the landing refinement uses.
    final pts = all.sublist(math.max(0, all.length - 14));
    if (pts.length < 5) return 20;
    // Least squares y = a t² + b t + c.
    final ts = pts.map((s) => (s.tMs - pts.first.tMs) / 1000).toList();
    final ys = pts.map((s) => s.p.y).toList();
    final ata = List.generate(3, (_) => List<double>.filled(3, 0));
    final atb = List<double>.filled(3, 0);
    for (var i = 0; i < ts.length; i++) {
      final row = [ts[i] * ts[i], ts[i], 1.0];
      for (var r = 0; r < 3; r++) {
        atb[r] += row[r] * ys[i];
        for (var c = 0; c < 3; c++) {
          ata[r][c] += row[r] * row[c];
        }
      }
    }
    final s = solveLinear(ata, atb);
    if (s == null) return 20;
    var sq = 0.0;
    for (var i = 0; i < ts.length; i++) {
      final e = s[0] * ts[i] * ts[i] + s[1] * ts[i] + s[2] - ys[i];
      sq += e * e;
    }
    return math.sqrt(sq / ts.length);
  }

  @override
  AttemptOutcome finalize() {
    final conf = _proposedCm == null
        ? 0.0
        : (cal.confidence * 0.4 + (100 * math.exp(-_fitResidualPx / 6)) * 0.45 + 12).clamp(5.0, 95.0);
    return AttemptOutcome(
      test: test,
      value: _proposedCm,
      confidence: conf,
      requiresScrub: true,
      fouls: _proposedCm == null ? const ['phase_ball_flight'] : const [],
      metadata: {
        'proposedFrame': proposedIndex,
        'trackPoints': track.length,
        'fitResidualPx': double.parse(_fitResidualPx.toStringAsFixed(2)),
        'calibration': cal.toJson(),
      },
    );
  }

  /// Final outcome after the assessor taps the exact landing point.
  AttemptOutcome confirmLanding(Vec2 tapPx, int frameIndex) {
    final d = distanceCmAt(tapPx);
    final base = finalize();
    final agree = _proposedCm == null ? 0.0 : (d - _proposedCm!).abs();
    return AttemptOutcome(
      test: test,
      value: d,
      // Human-confirmed point: confidence rests on calibration quality.
      confidence: (cal.confidence * 0.7 + 30 - math.min(agree, 20) * 0.5).clamp(5.0, 99.0),
      metadata: {
        ...base.metadata,
        'confirmedFrame': frameIndex,
        'aiProposedCm': _proposedCm == null ? null : double.parse(_proposedCm!.toStringAsFixed(1)),
        'scrubAdjustCm': double.parse(agree.toStringAsFixed(1)),
      },
    );
  }
}

/// Seated chest throw against a wall, with ballistic flight and bounce.
class MedicineBallSimulator extends FrameSimulator {
  MedicineBallSimulator({int seed = 13}) : _noise = SimNoise(seed) {
    statureM = _noise.uniform(1.35, 1.75);
    _rig = SideRig(statureM);
    cam = SimCamera(width: 720, height: 1280, focalPx: 820, position: (3.4, 1.5, -8.5), pitchDeg: 7);
    _distance = _noise.uniform(2.6, 5.8);
    _angle = _noise.uniform(0.6, 0.78);
    _plan();
  }

  final SimNoise _noise;
  late final double statureM;
  late final SideRig _rig;
  late final SimCamera cam;
  late final double _distance, _angle;
  static const ballR = 0.1;
  static const _release = 1.8;
  late (double, double) _p0;
  late double _v0, _tLand;

  @override
  SaiTest get test => SaiTest.medicineBall;
  @override
  double get width => cam.width;
  @override
  double get height => cam.height;
  @override
  double get fps => 60;
  @override
  double get durationMs => (_release + _tLand + 1.8) * 1000;

  void _plan() {
    final j = _rig.joints(_pose(_release));
    final sh = j[KP.leftShoulder]!;
    _p0 = (sh.$1 + 0.32 * statureM, sh.$2 - 0.02);
    // Solve v0 so the ball centre reaches height r at x = distance.
    final dx = _distance - _p0.$1, dy = ballR - _p0.$2;
    final c = math.cos(_angle), s = math.sin(_angle);
    _v0 = math.sqrt(kGravity * dx * dx / (2 * c * c * (dx * s / c - dy)));
    _tLand = dx / (_v0 * c);
  }

  RigPose _pose(double t) {
    final push = smoothstep(_release - 0.35, _release, t);
    final wind = smoothstep(0.6, 1.3, t) * (1 - push);
    return RigPose(
      hipX: 0.22,
      hipY: 0.1,
      facing: 1,
      torso: math.pi + 0.08 - 0.05 * push,
      thighL: math.pi / 2,
      shinL: math.pi / 2,
      thighR: math.pi / 2,
      shinR: math.pi / 2,
      upperArmL: lerpD(0.5, math.pi / 2 + 0.6, push) - wind * 0.2,
      forearmL: lerpD(2.4, math.pi / 2 + 0.6, push),
      upperArmR: lerpD(0.5, math.pi / 2 + 0.6, push) - wind * 0.2,
      forearmR: lerpD(2.4, math.pi / 2 + 0.6, push),
    );
  }

  (double, double) _ball(double t, Map<int, (double, double)> joints) {
    if (t < _release) {
      final w = joints[KP.leftWrist]!;
      return (w.$1 + 0.08, w.$2 + 0.02);
    }
    final c = math.cos(_angle), s = math.sin(_angle);
    final tau = t - _release;
    if (tau <= _tLand) {
      return (_p0.$1 + _v0 * c * tau, _p0.$2 + _v0 * s * tau - kGravity * tau * tau / 2);
    }
    // Bounce: restitution 0.35 vertical, 0.55 horizontal, then roll.
    final vxLand = _v0 * c, vyLand = _v0 * s - kGravity * _tLand;
    final vx = vxLand * 0.55, vy = -vyLand * 0.35;
    final tb = tau - _tLand;
    final bounceT = 2 * vy / kGravity;
    if (tb <= bounceT) {
      return (_distance + vx * tb, ballR + vy * tb - kGravity * tb * tb / 2);
    }
    final roll = tb - bounceT;
    final xr = _distance + vx * bounceT + vx * 0.6 * (1 - math.exp(-roll * 1.5)) / 1.5;
    return (xr, ballR);
  }

  @override
  PoseFrame frameAt(double tMs, int index) {
    final t = tMs / 1000;
    final pose = _pose(t);
    final j = _rig.joints(pose);
    final b = _ball(t, j);
    final ballPx = cam.project(b.$1, b.$2) + Vec2(_noise.gauss(0.7), _noise.gauss(0.7));
    return renderRig(rig: _rig, pose: pose, cam: cam, noise: _noise, tMs: tMs, index: index, ball: ballPx);
  }

  /// Ball radius in image pixels at a world X.
  double ballRadiusPx(double x) => cam.project(x, ballR).distanceTo(cam.project(x, 0));

  @override
  List<HudPrimitive> scenery(double tMs) => [
        HudLine(cam.project(-0.5, 0), cam.project(8, 0), tone: HudTone.neutral, width: 3),
        HudLine(cam.project(0, 0), cam.project(0, 2.2), tone: HudTone.neutral, width: 4, label: 'WALL'),
      ];

  @override
  Map<String, Object?> get groundTruth => {
        'trueDistanceCm': _distance * 100,
        'landingFrame': ((_release + _tLand) * fps).round(),
      };
}
