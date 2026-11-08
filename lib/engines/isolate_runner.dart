/// Background isolate for on-device pose inference.
///
/// The UI isolate only copies camera planes and posts them here; YUV/BGRA →
/// RGB conversion, rotation, letterboxing, TFLite MoveNet inference and the
/// cheap auxiliary vision (silhouette, ball blob, marker detection, scrubber
/// thumbnails) all run off the UI thread so the HUD stays at 60 FPS.
/// Frames arriving while a frame is in flight are dropped (back-pressure).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'calibration_engine.dart';
import 'pose_types.dart';

/// Camera planes copied out of a `CameraImage`.
class CameraFrameData {
  CameraFrameData({
    required this.width,
    required this.height,
    required this.planes,
    required this.rowStrides,
    required this.pixelStrides,
    required this.isBgra,
    required this.rotationDeg,
    required this.tMs,
    required this.index,
    this.mirror = false,
  });

  final int width;
  final int height;
  final List<Uint8List> planes;
  final List<int> rowStrides;
  final List<int> pixelStrides;
  final bool isBgra;

  /// Clockwise rotation that makes the frame upright (sensor orientation).
  final int rotationDeg;
  final double tMs;
  final int index;
  final bool mirror;

  int get outWidth => rotationDeg % 180 == 0 ? width : height;
  int get outHeight => rotationDeg % 180 == 0 ? height : width;
}

class FrameRequest {
  const FrameRequest({
    this.wantThumb = false,
    this.wantMarkers = false,
    this.markerCount = 1,
    this.wantBall = false,
    this.captureBackground = false,
  });
  final bool wantThumb;
  final bool wantMarkers;
  final int markerCount;
  final bool wantBall;

  /// Store this frame's thumbnail as the empty-scene background (calibration).
  final bool captureBackground;
}

class IsolateResult {
  const IsolateResult({
    required this.frame,
    this.thumb,
    this.thumbWidth = 0,
    this.thumbHeight = 0,
    this.markers = const [],
    this.inferenceMs = 0,
    this.poseMs = 0,
    this.convMs = 0,
    this.invokeMs = 0,
  });

  final PoseFrame frame;

  /// Grayscale upright thumbnail (for scrubbing / background).
  final Uint8List? thumb;
  final int thumbWidth;
  final int thumbHeight;
  final List<List<Vec2>> markers;
  final double inferenceMs;

  /// Conversion + TFLite inference only (excludes auxiliary vision).
  final double poseMs;
  final double convMs;
  final double invokeMs;
}

class PoseIsolateRunner {
  PoseIsolateRunner._(this._isolate, this._toIsolate, this._fromIsolate, this.inputSize, this.delegateInfo);

  final Isolate _isolate;
  final SendPort _toIsolate;
  final ReceivePort _fromIsolate;
  final int inputSize;
  final String delegateInfo;
  Completer<IsolateResult?>? _inFlight;
  int _seq = 0;

  bool get busy => _inFlight != null;

  /// Spawns the isolate and loads the model. Throws if the model cannot be loaded.
  /// Backend chosen by the first benchmark; later spawns skip benchmarking.
  static String? preferredBackend;

  static Future<PoseIsolateRunner> spawn(Uint8List modelBytes, {String? debugDumpPath}) async {
    final rp = ReceivePort();
    final isolate = await Isolate.spawn(_isolateMain, rp.sendPort, debugName: 'pose-isolate');
    final events = rp.asBroadcastStream();
    final toIsolate = await events.first as SendPort;
    toIsolate.send({
      'type': 'init',
      'model': TransferableTypedData.fromList([modelBytes]),
      'preferred': preferredBackend,
      'dump': debugDumpPath,
    });
    final init = await events.first as Map;
    if (init['ok'] != true) {
      isolate.kill(priority: Isolate.immediate);
      rp.close();
      throw StateError('Model load failed: ${init['error']}');
    }
    preferredBackend ??= init['backend'] as String?;
    final runner = PoseIsolateRunner._(isolate, toIsolate, rp, init['inputSize'] as int, '${init['delegate']}');
    events.listen(runner._onMessage);
    return runner;
  }

  void _onMessage(dynamic msg) {
    final c = _inFlight;
    _inFlight = null;
    if (c == null || c.isCompleted) return;
    if (msg is! Map || msg['ok'] != true) {
      c.complete(null);
      return;
    }
    final thumb = msg['thumb'] == null ? null : (msg['thumb'] as TransferableTypedData).materialize().asUint8List();
    c.complete(IsolateResult(
      frame: PoseFrame.fromJson((msg['frame'] as Map).cast<String, Object?>()),
      thumb: thumb,
      thumbWidth: msg['tw'] as int? ?? 0,
      thumbHeight: msg['th'] as int? ?? 0,
      markers: [
        for (final q in (msg['markers'] as List? ?? const []))
          [for (final p in (q as List)) Vec2.fromList(p as List)],
      ],
      inferenceMs: (msg['ms'] as num?)?.toDouble() ?? 0,
      poseMs: (msg['poseMs'] as num?)?.toDouble() ?? 0,
      convMs: (msg['convMs'] as num?)?.toDouble() ?? 0,
      invokeMs: (msg['invokeMs'] as num?)?.toDouble() ?? 0,
    ));
  }

  /// Returns null immediately if a frame is already in flight (frame dropped).
  Future<IsolateResult?> process(CameraFrameData f, [FrameRequest req = const FrameRequest()]) {
    if (_inFlight != null) return Future.value(null);
    final c = Completer<IsolateResult?>();
    _inFlight = c;
    _toIsolate.send({
      'type': 'frame',
      'seq': _seq++,
      'w': f.width,
      'h': f.height,
      'planes': [for (final p in f.planes) TransferableTypedData.fromList([p])],
      'rs': f.rowStrides,
      'ps': f.pixelStrides,
      'bgra': f.isBgra,
      'rot': f.rotationDeg,
      'mirror': f.mirror,
      't': f.tMs,
      'i': f.index,
      'thumb': req.wantThumb || req.captureBackground,
      'markers': req.wantMarkers,
      'markerCount': req.markerCount,
      'ball': req.wantBall,
      'bg': req.captureBackground,
    });
    return c.future;
  }

  void dispose() {
    _toIsolate.send({'type': 'close'});
    _fromIsolate.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    if (_inFlight?.isCompleted == false) _inFlight!.complete(null);
    _inFlight = null;
  }
}

// ===========================================================================
// Isolate side
// ===========================================================================

void _isolateMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  Interpreter? interpreter;
  var inputSize = 192;
  var inputIsFloat = false;
  Uint8List? background;
  Uint8List? prevThumb;
  Vec2? prevBall;
  String? dumpPath;
  var delegateInfo = '';
  var backendName = '';
  var convMs = 0.0, invokeMs = 0.0;

  inbox.listen((dynamic raw) {
    final msg = raw as Map;
    switch (msg['type']) {
      case 'init':
        try {
          final bytes = (msg['model'] as TransferableTypedData).materialize().asUint8List();
          // Backend auto-selection. Candidates are built-in interpreter options
          // only. Do NOT attach tflite_flutter's XNNPackDelegate explicitly: on
          // Android it segfaults inside TfLiteInterpreterCreate (native crash,
          // uncatchable from Dart; reproduced on Redmi Note 12 Pro).
          final preferred = msg['preferred'] as String?;
          final candidates = <String, InterpreterOptions Function()>{
            'cpu2': () => InterpreterOptions()..threads = 2,
            'cpu4': () => InterpreterOptions()..threads = 4,
            'nnapi': () => InterpreterOptions()..useNnApiForAndroid = true,
          };
          // Later launches re-check the cached winner against cheap 2-thread CPU:
          // accelerator speed varies with thermal/power state (observed NNAPI
          // 24 ms cold → 110 ms after ~30 min of camera use on a Redmi Note 12 Pro).
          final order = preferred != null && candidates.containsKey(preferred)
              ? {preferred, 'cpu2'}.toList()
              : candidates.keys.toList();
          final results = <String, double>{};
          Interpreter? best;
          var bestName = '';
          var bestMs = double.infinity;
          for (final name in order) {
            Interpreter? it;
            try {
              it = Interpreter.fromBuffer(bytes, options: candidates[name]!());
              final t = it.getInputTensor(0);
              final zeros = Uint8List(t.shape.reduce((a, b) => a * b) * (t.type == TensorType.float32 ? 4 : 1));
              t.setTo(zeros);
              it.invoke(); // warm-up / NNAPI compilation
              final times = <double>[];
              for (var i = 0; i < (order.length <= 2 ? 3 : 6); i++) {
                final sw = Stopwatch()..start();
                it.invoke();
                times.add(sw.elapsedMicroseconds / 1000);
              }
              final ms = median(times);
              results[name] = ms;
              if (ms < bestMs) {
                best?.close();
                best = it;
                bestName = name;
                bestMs = ms;
                it = null;
              }
            } catch (e) {
              results[name] = -1;
            } finally {
              it?.close();
            }
          }
          if (best == null) throw StateError('no TFLite backend could run the model: $results');
          interpreter = best;
          delegateInfo = '$bestName (${bestMs.toStringAsFixed(1)} ms) bench=${results.map((k, v) => MapEntry(k, v < 0 ? 'failed' : v.toStringAsFixed(1)))}';
          backendName = bestName;
          final input = interpreter!.getInputTensor(0);
          inputSize = input.shape[1];
          inputIsFloat = input.type == TensorType.float32;
          dumpPath = msg['dump'] as String?;
          out.send({'ok': true, 'inputSize': inputSize, 'delegate': delegateInfo, 'backend': backendName});
        } catch (e) {
          out.send({'ok': false, 'error': '$e'});
        }
      case 'frame':
        try {
          final sw = Stopwatch()..start();
          final f = CameraFrameData(
            width: msg['w'] as int,
            height: msg['h'] as int,
            planes: [for (final p in msg['planes'] as List) (p as TransferableTypedData).materialize().asUint8List()],
            rowStrides: (msg['rs'] as List).cast<int>(),
            pixelStrides: (msg['ps'] as List).cast<int>(),
            isBgra: msg['bgra'] as bool,
            rotationDeg: msg['rot'] as int,
            tMs: (msg['t'] as num).toDouble(),
            index: msg['i'] as int,
            mirror: msg['mirror'] as bool,
          );
          final sampler = _Sampler(f);
          final (kps, rgb, conv, inv) = _runPose(interpreter!, sampler, inputSize, inputIsFloat);
          convMs = conv;
          invokeMs = inv;
          final poseMs = sw.elapsedMicroseconds / 1000;

          // One-off debug dump of the exact MoveNet input (verifies rotation/colour).
          if (dumpPath != null) {
            final path = dumpPath!;
            dumpPath = null;
            final im = img.Image.fromBytes(width: inputSize, height: inputSize, bytes: rgb.buffer, numChannels: 3);
            File(path).writeAsBytesSync(img.encodePng(im));
          }

          // Thumbnail only when something needs it (silhouette, ball, scrubber, background).
          final person = mean(kps.map((k) => k.score)) >= 0.25;
          final needThumb = msg['thumb'] == true || msg['bg'] == true || msg['ball'] == true ||
              (background != null && person);
          final tw = math.min(180, sampler.outW);
          final th = (sampler.outH * tw / sampler.outW).round();
          final thumb = needThumb ? sampler.grayThumb(tw, th) : Uint8List(0);
          final scale = sampler.outW / tw;

          if (msg['bg'] == true) background = thumb;

          Vec2? silTop, silBottom;
          if (background != null && person && thumb.isNotEmpty) {
            final (t, b) = _silhouette(thumb, background!, tw, th, kps, scale);
            silTop = t;
            silBottom = b;
          }

          Vec2? ball;
          if (msg['ball'] == true && prevThumb != null && prevThumb!.length == thumb.length) {
            ball = _ballBlob(thumb, prevThumb!, tw, th, kps, scale, prevBall);
            prevBall = ball ?? prevBall;
          }
          if (thumb.isNotEmpty) prevThumb = thumb;

          var markers = <List<Vec2>>[];
          if (msg['markers'] == true) {
            // Full resolution (up to 720 px wide): corner error is 1/2 of a 360 px search.
            final mw = math.min(720, sampler.outW);
            final mh = (sampler.outH * mw / sampler.outW).round();
            final gray = sampler.grayThumb(mw, mh);
            final ms = sampler.outW / mw;
            markers = [
              for (final q in detectSquareMarkers(gray, mw, mh, maxMarkers: msg['markerCount'] as int))
                [for (final p in q) p * ms],
            ];
          }

          final frame = PoseFrame(
            tMs: f.tMs,
            width: sampler.outW.toDouble(),
            height: sampler.outH.toDouble(),
            keypoints: kps,
            ball: ball,
            silhouetteTop: silTop,
            silhouetteBottom: silBottom,
            index: f.index,
          );
          out.send({
            'ok': true,
            'frame': frame.toJson(),
            if (msg['thumb'] == true) 'thumb': TransferableTypedData.fromList([thumb]),
            'tw': tw,
            'th': th,
            'markers': [for (final q in markers) [for (final p in q) p.toList()]],
            'ms': sw.elapsedMicroseconds / 1000,
            'poseMs': poseMs,
            'convMs': convMs,
            'invokeMs': invokeMs,
          });
        } catch (e) {
          out.send({'ok': false, 'error': '$e'});
        }
      case 'close':
        interpreter?.close();
        inbox.close();
    }
  });
}

/// Samples the upright (rotated, optionally mirrored) image from raw planes.
///
/// Rotation + mirror are folded into one integer affine map computed once per
/// frame (sx = sx0 + sxx·ox + sxy·oy, sy = sy0 + syx·ox + syy·oy), so the hot
/// loops are pure typed-array index arithmetic: no records, no switches.
class _Sampler {
  _Sampler(this.f)
      : outW = f.outWidth,
        outH = f.outHeight,
        _y = f.planes[0],
        _u = f.planes.length > 1 ? f.planes[1] : Uint8List(0),
        _v = f.planes.length > 2 ? f.planes[2] : Uint8List(0),
        _rs = f.rowStrides[0],
        _uvRow = f.rowStrides.length > 1 ? f.rowStrides[1] : 0,
        _uvPix = f.pixelStrides.length > 1 ? f.pixelStrides[1] : 1 {
    final w = f.width, h = f.height;
    final m = switch (f.rotationDeg) {
      90 => (0, 1, 0, -1, 0, h - 1),
      180 => (-1, 0, w - 1, 0, -1, h - 1),
      270 => (0, -1, w - 1, 1, 0, 0),
      _ => (1, 0, 0, 0, 1, 0),
    };
    sxx = m.$1;
    sxy = m.$2;
    sx0 = m.$3;
    syx = m.$4;
    syy = m.$5;
    sy0 = m.$6;
    if (f.mirror) {
      // ox → outW−1−ox
      sx0 += sxx * (outW - 1);
      sxx = -sxx;
      sy0 += syx * (outW - 1);
      syx = -syx;
    }
  }

  final CameraFrameData f;
  final int outW, outH;
  final Uint8List _y, _u, _v;
  final int _rs, _uvRow, _uvPix;
  late int sxx, sxy, sx0, syx, syy, sy0;

  /// Downsampled upright grayscale (luma) image.
  Uint8List grayThumb(int tw, int th) {
    final out = Uint8List(tw * th);
    final stepX = outW / tw, stepY = outH / th;
    final bgra = f.isBgra;
    var o = 0;
    for (var y = 0; y < th; y++) {
      final oy = math.min(outH - 1, (y * stepY).toInt());
      final bx = sx0 + sxy * oy, by = sy0 + syy * oy;
      for (var x = 0; x < tw; x++) {
        final ox = math.min(outW - 1, (x * stepX).toInt());
        final sx = bx + sxx * ox, sy = by + syx * ox;
        if (bgra) {
          final i = sy * _rs + sx * 4;
          out[o++] = (_y[i + 2] * 77 + _y[i + 1] * 150 + _y[i] * 29) >> 8;
        } else {
          out[o++] = _y[sy * _rs + sx];
        }
      }
    }
    return out;
  }

  /// Letterboxed size×size RGB (uint8) model input.
  Uint8List modelInput(int size, double scale, double padX, double padY) {
    final buf = Uint8List(size * size * 3);
    final bgra = f.isBgra;
    final hasUv = _u.isNotEmpty && _v.isNotEmpty;
    for (var iy = 0; iy < size; iy++) {
      final oy = ((iy - padY) / scale).floor();
      if (oy < 0 || oy >= outH) continue;
      final bx = sx0 + sxy * oy, by = sy0 + syy * oy;
      var o = iy * size * 3;
      for (var ix = 0; ix < size; ix++, o += 3) {
        final ox = ((ix - padX) / scale).floor();
        if (ox < 0 || ox >= outW) continue;
        final sx = bx + sxx * ox, sy = by + syx * ox;
        if (bgra) {
          final i = sy * _rs + sx * 4;
          buf[o] = _y[i + 2];
          buf[o + 1] = _y[i + 1];
          buf[o + 2] = _y[i];
          continue;
        }
        final yv = _y[sy * _rs + sx];
        if (!hasUv) {
          buf[o] = buf[o + 1] = buf[o + 2] = yv;
          continue;
        }
        final uvi = (sy >> 1) * _uvRow + (sx >> 1) * _uvPix;
        final u = (uvi < _u.length ? _u[uvi] : 128) - 128;
        final v = (uvi < _v.length ? _v[uvi] : 128) - 128;
        // Integer BT.601 (×1024).
        final r = yv + ((1436 * v) >> 10);
        final g = yv - ((352 * u + 731 * v) >> 10);
        final b = yv + ((1815 * u) >> 10);
        buf[o] = r < 0 ? 0 : (r > 255 ? 255 : r);
        buf[o + 1] = g < 0 ? 0 : (g > 255 ? 255 : g);
        buf[o + 2] = b < 0 ? 0 : (b > 255 ? 255 : b);
      }
    }
    return buf;
  }
}

/// Runs MoveNet. Returns keypoints in upright image pixels plus the raw input (for debug dumps).
(List<Keypoint>, Uint8List, double, double) _runPose(Interpreter interp, _Sampler s, int size, bool isFloat) {
  final sw = Stopwatch()..start();
  final scale = size / math.max(s.outW, s.outH);
  final padX = (size - s.outW * scale) / 2, padY = (size - s.outH * scale) / 2;
  final rgb = s.modelInput(size, scale, padX, padY);
  final input = interp.getInputTensor(0);
  if (isFloat) {
    final fl = Float32List(rgb.length);
    for (var i = 0; i < rgb.length; i++) {
      fl[i] = rgb[i].toDouble();
    }
    input.setTo(fl.buffer.asUint8List());
  } else {
    input.setTo(rgb);
  }
  final conv = sw.elapsedMicroseconds / 1000;
  interp.invoke();
  final inv = sw.elapsedMicroseconds / 1000 - conv;
  final outT = interp.getOutputTensor(0);
  final raw = outT.copyTo(Uint8List(outT.numBytes())) as Uint8List;
  final out = raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);
  final kps = List<Keypoint>.generate(KP.count, (i) {
    final y = out[i * 3] * size, x = out[i * 3 + 1] * size, score = out[i * 3 + 2];
    return Keypoint(Vec2((x - padX) / scale, (y - padY) / scale), score.toDouble());
  });
  return (kps, rgb, conv, inv);
}

/// Top / bottom of the athlete's foreground (vs. the empty calibration scene),
/// restricted to a column band around the detected body.
(Vec2?, Vec2?) _silhouette(Uint8List cur, Uint8List bg, int w, int h, List<Keypoint> kps, double scale) {
  final good = kps.where((k) => k.score > 0.3).toList();
  if (good.length < 5) return (null, null);
  final cx = mean(good.map((k) => k.p.x)) / scale;
  final xs = good.map((k) => k.p.x / scale).toList()..sort();
  final half = math.max((xs.last - xs.first) / 2 + 2, w * 0.06);
  final x0 = (cx - half).floor().clamp(0, w - 1), x1 = (cx + half).ceil().clamp(0, w - 1);
  bool rowHit(int y) {
    var n = 0;
    for (var x = x0; x <= x1; x++) {
      if ((cur[y * w + x] - bg[y * w + x]).abs() > 28) n++;
      if (n >= 2) return true;
    }
    return false;
  }

  int? top, bottom;
  for (var y = 0; y < h - 1; y++) {
    if (rowHit(y) && rowHit(y + 1)) {
      top = y;
      break;
    }
  }
  for (var y = h - 1; y > 0; y--) {
    if (rowHit(y) && rowHit(y - 1)) {
      bottom = y;
      break;
    }
  }
  if (top == null || bottom == null || bottom - top < h * 0.2) return (null, null);
  return (Vec2(cx * scale, (top + 0.5) * scale), Vec2(cx * scale, (bottom + 0.5) * scale));
}

/// Small moving blob outside the athlete's body box (the thrown ball).
Vec2? _ballBlob(Uint8List cur, Uint8List prev, int w, int h, List<Keypoint> kps, double scale, Vec2? last) {
  final good = kps.where((k) => k.score > 0.3).toList();
  double bx0 = -1, bx1 = -1, by0 = -1, by1 = -1;
  if (good.length >= 5) {
    final xs = good.map((k) => k.p.x / scale), ys = good.map((k) => k.p.y / scale);
    bx0 = xs.reduce(math.min) - 3;
    bx1 = xs.reduce(math.max) + 3;
    by0 = ys.reduce(math.min) - 6;
    by1 = ys.reduce(math.max) + 3;
  }
  final mask = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final inBody = x >= bx0 && x <= bx1 && y >= by0 && y <= by1;
      if (!inBody && (cur[y * w + x] - prev[y * w + x]).abs() > 30) mask[y * w + x] = 1;
    }
  }
  Vec2? best;
  var bestScore = -1e9;
  final stack = <int>[];
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] != 1) continue;
    var n = 0;
    var sx = 0.0, sy = 0.0;
    stack
      ..clear()
      ..add(i);
    mask[i] = 2;
    while (stack.isNotEmpty) {
      final j = stack.removeLast();
      final x = j % w, y = j ~/ w;
      n++;
      sx += x;
      sy += y;
      for (final k in [j - 1, j + 1, j - w, j + w]) {
        if (k >= 0 && k < mask.length && mask[k] == 1 && ((k % w) - x).abs() <= 1) {
          mask[k] = 2;
          stack.add(k);
        }
      }
    }
    if (n < 2 || n > 300) continue;
    final c = Vec2(sx / n * scale, sy / n * scale);
    final score = last == null ? n.toDouble() : -c.distanceTo(last) + n * 0.5;
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return best;
}
