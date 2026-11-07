import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';
import '../../engines/assisted_ocr_engine.dart';
import '../../engines/pose_types.dart';
import 'hud_painter.dart';

/// Converts an 8-bit grayscale buffer to a ui.Image.
Future<ui.Image> grayToImage(Uint8List gray, int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    final v = gray[i];
    rgba[i * 4] = v;
    rgba[i * 4 + 1] = v;
    rgba[i * 4 + 2] = v;
    rgba[i * 4 + 3] = 255;
  }
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

class GrayThumb {
  const GrayThumb(this.data, this.width, this.height);
  final Uint8List data;
  final int width;
  final int height;
}

/// Slow-motion frame scrubber: the AI proposes the first-bounce frame; the
/// assessor scrubs and taps the exact landing point.
Future<(Vec2, int)?> showLandingScrubber(
  BuildContext context, {
  required MedicineBallSession session,
  required List<HudPrimitive> Function(double tMs) scenery,
  required bool simulated,
  required double ballRadiusPx,
  Map<int, GrayThumb> thumbs = const {},
}) =>
    Navigator.of(context).push<(Vec2, int)>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _Scrubber(
        session: session,
        scenery: scenery,
        simulated: simulated,
        ballRadiusPx: ballRadiusPx,
        thumbs: thumbs,
      ),
    ));

class _Scrubber extends ConsumerStatefulWidget {
  const _Scrubber({
    required this.session,
    required this.scenery,
    required this.simulated,
    required this.ballRadiusPx,
    required this.thumbs,
  });

  final MedicineBallSession session;
  final List<HudPrimitive> Function(double tMs) scenery;
  final bool simulated;
  final double ballRadiusPx;
  final Map<int, GrayThumb> thumbs;

  @override
  ConsumerState<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends ConsumerState<_Scrubber> {
  late final ValueNotifier<HudFrame> _hud;
  late int _index, _lo, _hi;
  Vec2? _tap;
  Timer? _play;
  final _imageCache = <int, ui.Image>{};

  List<PoseFrame> get frames => widget.session.frames;

  @override
  void initState() {
    super.initState();
    final proposed = widget.session.proposedIndex ?? (frames.length - 1);
    _lo = (proposed - 50).clamp(0, frames.length - 1);
    _hi = (proposed + 40).clamp(0, frames.length - 1);
    _index = proposed.clamp(_lo, _hi);
    final ball = frames[_index].ball;
    _tap = ball == null ? null : widget.session.contactPoint(ball);
    final f = frames.first;
    _hud = ValueNotifier(HudFrame(imageWidth: f.width, imageHeight: f.height, simulated: widget.simulated));
    _render();
  }

  @override
  void dispose() {
    _play?.cancel();
    _hud.dispose();
    for (final img in _imageCache.values) {
      img.dispose();
    }
    super.dispose();
  }

  Future<void> _render() async {
    final f = frames[_index];
    ui.Image? img;
    final thumb = widget.thumbs[f.index];
    if (!widget.simulated && thumb != null) {
      img = _imageCache[f.index] ??= await grayToImage(thumb.data, thumb.width, thumb.height);
    }
    if (!mounted) return;
    _hud.value = HudFrame(
      imageWidth: f.width,
      imageHeight: f.height,
      frame: f,
      scenery: widget.scenery(f.tMs),
      simulated: widget.simulated,
      ballRadiusPx: widget.ballRadiusPx,
      tapMarker: _tap,
      thumb: img,
      snapshot: EngineSnapshot(phaseKey: 'phase_ball_landed', overlay: [
        if (widget.session.proposedIndex != null && frames[widget.session.proposedIndex!].ball != null)
          HudPoint(widget.session.contactPoint(frames[widget.session.proposedIndex!].ball!),
              tone: HudTone.warning, radius: 6, label: 'AI'),
      ]),
    );
  }

  void _seek(int i) {
    setState(() => _index = i.clamp(_lo, _hi));
    _render();
  }

  void _togglePlay() {
    if (_play != null) {
      _play!.cancel();
      setState(() => _play = null);
      return;
    }
    // 0.25× slow motion of a 60 FPS capture ≈ one frame every 67 ms.
    setState(() {
      _play = Timer.periodic(const Duration(milliseconds: 67), (_) {
        if (_index >= _hi) {
          _seek(_lo);
        } else {
          _seek(_index + 1);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(l10nProvider);
    final f = frames[_index];
    final distance = _tap == null ? null : widget.session.distanceCmAt(_tap!);
    return Scaffold(
      backgroundColor: AppColors.hudBackdrop,
      appBar: AppBar(
        backgroundColor: AppColors.hudBackdrop,
        foregroundColor: Colors.white,
        title: Text(l.t('wb_scrub_title'), style: const TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
              child: Text(
                l.t('wb_scrub_hint', {'frame': widget.session.proposedIndex ?? '—'}),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) => GestureDetector(
                  onTapDown: (d) {
                    final tf = HudTransform(c.biggest, f.width, f.height);
                    setState(() => _tap = tf.unmap(d.localPosition));
                    _render();
                  },
                  child: CustomPaint(painter: HudPainter(_hud), size: c.biggest),
                ),
              ),
            ),
            Container(
              color: AppColors.surface,
              padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.sm, AppSpace.md, AppSpace.sm),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text('#${f.index}', style: AppText.metricS.copyWith(color: AppColors.text)),
                      Expanded(
                        child: Slider(
                          min: _lo.toDouble(),
                          max: _hi.toDouble(),
                          value: _index.toDouble(),
                          onChanged: (v) => _seek(v.round()),
                        ),
                      ),
                      Text(distance == null ? '—' : '${distance.toStringAsFixed(0)} cm', style: AppText.metricM),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.outlined(onPressed: () => _seek(_index - 1), icon: const Icon(Icons.chevron_left_rounded)),
                      const SizedBox(width: AppSpace.sm),
                      IconButton.filled(
                        onPressed: _togglePlay,
                        icon: Icon(_play == null ? Icons.slow_motion_video_rounded : Icons.pause_rounded),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      IconButton.outlined(onPressed: () => _seek(_index + 1), icon: const Icon(Icons.chevron_right_rounded)),
                    ],
                  ),
                  const SizedBox(height: AppSpace.sm),
                  PrimaryButton(
                    label: l.t('wb_scrub_confirm'),
                    icon: Icons.check_rounded,
                    onPressed: _tap == null ? null : () => Navigator.pop(context, (_tap!, f.index)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
