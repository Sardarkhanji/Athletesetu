import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../engines/pose_types.dart';

/// Everything the HUD needs for one repaint. Pushed through a ValueNotifier so
/// only the CustomPaint repaints per frame (no widget rebuilds).
class HudFrame {
  const HudFrame({
    required this.imageWidth,
    required this.imageHeight,
    this.frame,
    this.snapshot = EngineSnapshot.idle,
    this.scenery = const [],
    this.markers = const [],
    this.gateLines = const [],
    this.showGateHandles = false,
    this.simulated = false,
    this.ballRadiusPx = 14,
    this.tapMarker,
    this.thumb,
  });

  final double imageWidth;
  final double imageHeight;
  final PoseFrame? frame;
  final EngineSnapshot snapshot;
  final List<HudPrimitive> scenery;
  final List<List<Vec2>> markers;
  final List<double> gateLines;
  final bool showGateHandles;

  /// Draws the synthetic scene backdrop (Demo Simulation Mode).
  final bool simulated;
  final double ballRadiusPx;

  /// Assessor's landing tap (medicine-ball scrubber).
  final Vec2? tapMarker;

  /// Grayscale frame (real-mode scrubber) drawn under the overlay.
  final ui.Image? thumb;

  static const empty = HudFrame(imageWidth: 720, imageHeight: 1280);
}

Color toneColor(HudTone t) => switch (t) {
      HudTone.neutral => Colors.white70,
      HudTone.primary => const Color(0xFF60A5FA), // lighter cobalt for dark backdrops
      HudTone.pass => AppColors.pass,
      HudTone.warning => AppColors.warning,
      HudTone.foul => AppColors.foul,
    };

/// Maps image pixels into the widget with BoxFit.contain.
class HudTransform {
  HudTransform(Size size, double iw, double ih)
      : scale = math.min(size.width / iw, size.height / ih),
        dx = (size.width - iw * math.min(size.width / iw, size.height / ih)) / 2,
        dy = (size.height - ih * math.min(size.width / iw, size.height / ih)) / 2;

  final double scale, dx, dy;

  Offset map(Vec2 p) => Offset(dx + p.x * scale, dy + p.y * scale);
  Vec2 unmap(Offset o) => Vec2((o.dx - dx) / scale, (o.dy - dy) / scale);
}

class HudPainter extends CustomPainter {
  HudPainter(this.notifier) : super(repaint: notifier);

  final ValueNotifier<HudFrame> notifier;

  @override
  void paint(Canvas canvas, Size size) {
    final h = notifier.value;
    final tf = HudTransform(size, h.imageWidth, h.imageHeight);
    final imageRect = Rect.fromLTWH(tf.dx, tf.dy, h.imageWidth * tf.scale, h.imageHeight * tf.scale);

    if (h.thumb != null) {
      paintImage(canvas: canvas, rect: imageRect, image: h.thumb!, fit: BoxFit.fill, filterQuality: FilterQuality.low);
    } else if (h.simulated) {
      canvas.drawRect(imageRect, Paint()..color = AppColors.hudBackdrop);
      final grid = Paint()
        ..color = Colors.white.withValues(alpha: 0.04)
        ..strokeWidth = 1;
      for (var x = 0.0; x < h.imageWidth; x += 80) {
        canvas.drawLine(tf.map(Vec2(x, 0)), tf.map(Vec2(x, h.imageHeight)), grid);
      }
      for (var y = 0.0; y < h.imageHeight; y += 80) {
        canvas.drawLine(tf.map(Vec2(0, y)), tf.map(Vec2(h.imageWidth, y)), grid);
      }
    }

    canvas.save();
    canvas.clipRect(imageRect);
    for (final p in h.scenery) {
      _primitive(canvas, tf, p, muted: true);
    }
    for (final q in h.markers) {
      _primitive(canvas, tf, HudPolygon(q, tone: HudTone.pass, fill: true));
      for (final c in q) {
        canvas.drawCircle(tf.map(c), 4, Paint()..color = AppColors.pass);
      }
    }
    if (h.showGateHandles) {
      for (var i = 0; i < h.gateLines.length; i++) {
        final x = h.gateLines[i];
        _dashed(canvas, tf.map(Vec2(x, 0)), tf.map(Vec2(x, h.imageHeight)),
            Paint()
              ..color = AppColors.warning
              ..strokeWidth = 3);
        final c = tf.map(Vec2(x, h.imageHeight * 0.5));
        canvas.drawCircle(c, 22, Paint()..color = AppColors.warning.withValues(alpha: 0.85));
        _label(canvas, h.gateLines.length > 1 ? (i == 0 ? 'A' : 'B') : '⇆', c - const Offset(6, 9), Colors.black, 16);
      }
    }

    final f = h.frame;
    if (f != null && f.hasPerson) _skeleton(canvas, tf, f);
    if (f?.ball != null) {
      final c = tf.map(f!.ball!);
      final r = h.ballRadiusPx * tf.scale;
      canvas.drawCircle(c, r, Paint()..color = AppColors.warning);
      canvas.drawCircle(c, r, Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
    for (final p in h.snapshot.overlay) {
      _primitive(canvas, tf, p);
    }
    if (h.tapMarker != null) {
      final c = tf.map(h.tapMarker!);
      final paint = Paint()
        ..color = AppColors.pass
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(c, 16, paint);
      canvas.drawLine(c - const Offset(24, 0), c + const Offset(24, 0), paint);
      canvas.drawLine(c - const Offset(0, 24), c + const Offset(0, 24), paint);
    }
    canvas.restore();
  }

  void _skeleton(Canvas canvas, HudTransform tf, PoseFrame f) {
    final bone = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (final (a, b) in KP.edges) {
      final ka = f[a], kb = f[b];
      if (ka.score < 0.25 || kb.score < 0.25) continue;
      final s = math.min(ka.score, kb.score);
      bone.color = (s > 0.5 ? AppColors.pass : AppColors.warning).withValues(alpha: 0.9);
      canvas.drawLine(tf.map(ka.p), tf.map(kb.p), bone);
    }
    final joint = Paint()..color = Colors.white;
    for (final k in f.keypoints) {
      if (k.score < 0.25) continue;
      canvas.drawCircle(tf.map(k.p), 3.5, joint);
    }
  }

  void _primitive(Canvas canvas, HudTransform tf, HudPrimitive p, {bool muted = false}) {
    final color = toneColor(p.tone).withValues(alpha: muted ? 0.35 : 1);
    switch (p) {
      case HudLine(:final a, :final b, :final dashed, :final width):
        final paint = Paint()
          ..color = color
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round;
        if (dashed) {
          _dashed(canvas, tf.map(a), tf.map(b), paint);
        } else {
          canvas.drawLine(tf.map(a), tf.map(b), paint);
        }
        if (p.label != null) _label(canvas, p.label!, tf.map(a) + const Offset(6, -18), color, 12);
      case HudPoint(:final p, :final radius):
        final c = tf.map(p);
        canvas.drawCircle(c, radius, Paint()..color = color);
        canvas.drawCircle(c, radius + 3, Paint()
          ..color = color.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
      case HudPolygon(:final points, :final fill):
        if (points.length < 2) return;
        final path = Path()..moveTo(tf.map(points.first).dx, tf.map(points.first).dy);
        for (final q in points.skip(1)) {
          path.lineTo(tf.map(q).dx, tf.map(q).dy);
        }
        path.close();
        if (fill) canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.18));
        canvas.drawPath(path, Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
      case HudPath(:final points):
        if (points.length < 2) return;
        final path = Path()..moveTo(tf.map(points.first).dx, tf.map(points.first).dy);
        for (final q in points.skip(1)) {
          path.lineTo(tf.map(q).dx, tf.map(q).dy);
        }
        canvas.drawPath(path, Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 10.0, gap = 7.0;
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final e = math.min(d + dash, total);
      canvas.drawLine(a + dir * d, a + dir * e, paint);
      d = e + gap;
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w700, fontFamily: 'NotoSans'),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant HudPainter old) => old.notifier != notifier;
}
