import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';
import '../../engines/assisted_ocr_engine.dart';
import '../../engines/pose_types.dart' show AttemptOutcome;
import 'scrubber_sheet.dart' show grayToImage;

/// Decodes a photo to an upright grayscale buffer ≤ 900 px wide (runs in an isolate).
GrayImage _decodeGray(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Unsupported image');
  final upright = img.bakeOrientation(decoded);
  final resized = upright.width > 900 ? img.copyResize(upright, width: 900) : upright;
  final gray = img.grayscale(resized);
  return GrayImage(gray.width, gray.height, gray.getBytes(order: img.ChannelOrder.red));
}

/// Weight station: photograph the scale display, frame the digits, read offline.
class WeightCaptureView extends ConsumerStatefulWidget {
  const WeightCaptureView({
    super.key,
    required this.simulated,
    required this.heightCm,
    required this.onOutcome,
  });

  final bool simulated;
  final double? heightCm;
  final void Function(AttemptOutcome outcome, Map<String, Object?> truth) onOutcome;

  @override
  ConsumerState<WeightCaptureView> createState() => _WeightCaptureViewState();
}

class _WeightCaptureViewState extends ConsumerState<WeightCaptureView> {
  GrayImage? _gray;
  ui.Image? _preview;
  NormRect _roi = const NormRect(0.1, 0.3, 0.8, 0.4);
  Offset? _dragStart;
  bool _busy = false;
  double? _truthKg;
  int _seed = DateTime.now().millisecondsSinceEpoch % 100000;

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  Future<void> _setImage(GrayImage g, NormRect roi) async {
    final preview = await grayToImage(g.data, g.width, g.height);
    if (!mounted) return;
    setState(() {
      _preview?.dispose();
      _preview = preview;
      _gray = g;
      _roi = roi;
    });
  }

  Future<void> _simulate() async {
    final r = math.Random(_seed++);
    final h = (widget.heightCm ?? 145) / 100;
    final kg = double.parse((h * h * (14.5 + r.nextDouble() * 9)).toStringAsFixed(1));
    final (g, roi) = ScaleDisplaySimulator(seed: _seed).render(kg);
    _truthKg = kg;
    await _setImage(g, roi);
  }

  Future<void> _capture() async {
    final l = ref.read(l10nProvider);
    setState(() => _busy = true);
    try {
      final shot = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1800, imageQuality: 92);
      if (shot == null) return;
      final g = await compute(_decodeGray, await shot.readAsBytes());
      _truthKg = null;
      await _setImage(g, const NormRect(0.1, 0.3, 0.8, 0.4));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('error_generic', {'msg': e}))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _read() {
    final g = _gray;
    if (g == null) return;
    setState(() => _busy = true);
    final outcome = const WeightOcrEngine().read(g, roi: _roi, heightCm: widget.heightCm, simulated: widget.simulated);
    setState(() => _busy = false);
    widget.onOutcome(outcome, {if (_truthKg != null) 'trueKg': _truthKg});
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(l10nProvider);
    return Column(
      children: [
        Expanded(
          child: Container(
            color: AppColors.hudBackdrop,
            alignment: Alignment.center,
            child: _preview == null
                ? Padding(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    child: Text(l.t('test_weight_setup'),
                        textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                  )
                : AspectRatio(
                    aspectRatio: _preview!.width / _preview!.height,
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final size = c.biggest;
                        Offset clampOff(Offset o) =>
                            Offset(o.dx.clamp(0, size.width), o.dy.clamp(0, size.height));
                        return GestureDetector(
                          onPanStart: (d) => _dragStart = clampOff(d.localPosition),
                          onPanUpdate: (d) {
                            final a = _dragStart!, b = clampOff(d.localPosition);
                            final r = Rect.fromPoints(a, b);
                            if (r.width < 20 || r.height < 12) return;
                            setState(() => _roi = NormRect(
                                  r.left / size.width,
                                  r.top / size.height,
                                  r.width / size.width,
                                  r.height / size.height,
                                ));
                          },
                          child: CustomPaint(
                            painter: _RoiPainter(_preview!, _roi),
                            size: size,
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.all(AppSpace.md),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.heightCm == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.sm),
                    child: StatusPill(label: l.t('wb_bmi_missing'), color: AppColors.warning, icon: Icons.info_outline),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : (widget.simulated ? _simulate : _capture),
                        icon: Icon(widget.simulated ? Icons.science_outlined : Icons.photo_camera_outlined),
                        label: Text(
                          widget.simulated ? l.t('wb_simulation') : l.t('wb_capture_scale'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: PrimaryButton(
                        label: l.t('wb_ocr_reading').replaceAll('…', ''),
                        icon: Icons.document_scanner_outlined,
                        busy: _busy,
                        onPressed: _gray == null ? null : _read,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RoiPainter extends CustomPainter {
  _RoiPainter(this.image, this.roi);
  final ui.Image image;
  final NormRect roi;

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: Offset.zero & size, image: image, fit: BoxFit.fill);
    final r = Rect.fromLTWH(roi.left * size.width, roi.top * size.height, roi.width * size.width, roi.height * size.height);
    final shade = Path()
      ..addRect(Offset.zero & size)
      ..addRect(r)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.45));
    canvas.drawRect(r, Paint()
      ..color = AppColors.pass
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(c, 6, Paint()..color = AppColors.pass);
    }
  }

  @override
  bool shouldRepaint(covariant _RoiPainter old) => old.image != image || old.roi != roi;
}

