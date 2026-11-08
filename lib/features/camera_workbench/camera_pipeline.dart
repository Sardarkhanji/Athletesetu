import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../engines/calibration_engine.dart';
import '../../engines/isolate_runner.dart';
import '../../engines/timing_gate_engine.dart' show MonotonicClock;

/// Camera → background isolate → results. Also records the attempt video.
class CameraPipeline {
  CameraController? controller;
  PoseIsolateRunner? _runner;
  CameraDescription? _description;
  final fps = FrameRateMeter();
  int _index = 0;
  bool _streaming = false;
  bool _recording = false;

  /// Capture locked to landscape (top of the phone to the left) instead of portrait.
  bool _landscape = false;
  bool get landscape => _landscape;

  // Diagnostics (logged once per second as `[AthleteSetu] cam …`).
  int _received = 0, _dropped = 0, _processed = 0;
  double _inferSum = 0, _poseSum = 0, _convSum = 0, _invokeSum = 0, _kpSum = 0, _lastStatMs = 0;
  bool _formatLogged = false;
  bool _rotationFixLogged = false;

  static void log(String msg) => debugPrint('[AthleteSetu] $msg');

  /// Result callback (UI isolate).
  void Function(IsolateResult result)? onResult;

  /// Per-frame request flags (markers, thumbnails, ball…).
  FrameRequest Function() requestFor = () => const FrameRequest();

  static const modelAssets = [
    'assets/models/movenet_lightning_int8.tflite',
    'assets/models/movenet_thunder_int8.tflite',
  ];

  /// Loads the bundled pose model, or null if none is present yet.
  static Future<Uint8List?> loadModel() async {
    for (final name in modelAssets) {
      try {
        final d = await rootBundle.load(name);
        log('model loaded: $name (${(d.lengthInBytes / 1024).round()} KB)');
        return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
      } catch (_) {
        // Not bundled.
      }
    }
    log('no pose model bundled → Demo Simulation Mode');
    return null;
  }

  bool get isReady => controller?.value.isInitialized ?? false;

  /// Upright frame size: portrait (tall) or landscape (wide), as the test asks.
  Size? get uprightSize {
    final s = controller?.value.previewSize;
    if (s == null) return null;
    return _landscape ? Size(s.longestSide, s.shortestSide) : Size(s.shortestSide, s.longestSide);
  }

  /// Clockwise rotation that turns a raw sensor buffer upright for the locked
  /// orientation. Analysis buffers always arrive in sensor orientation; portrait
  /// needs the sensor angle (usually 90°), landscape-left needs 90° less.
  int get _frameRotationDeg {
    final sensor = _description?.sensorOrientation ?? 90;
    final display = _landscape ? 90 : 0;
    final front = _description?.lensDirection == CameraLensDirection.front;
    return front ? (sensor + display) % 360 : (sensor - display + 360) % 360;
  }

  Future<void> init({required Uint8List model, required bool highFps, bool landscape = false}) async {
    _landscape = landscape;
    final cameras = await availableCameras();
    log('cameras: ${cameras.map((c) => '${c.name}/${c.lensDirection.name}/${c.sensorOrientation}°').join(', ')}');
    if (cameras.isEmpty) throw CameraException('no_camera', 'No camera found');
    _description = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final c = CameraController(
      _description!,
      ResolutionPreset.high, // 720p baseline
      enableAudio: true,
      fps: highFps ? 60 : 30,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
    );
    try {
      await c.initialize();
    } on CameraException catch (e) {
      log('init at ${highFps ? 60 : 30} FPS rejected (${e.code}); retrying default rate');
      // Some devices reject 60 FPS: retry at the default rate.
      await c.dispose();
      final fallback = CameraController(_description!, ResolutionPreset.high,
          enableAudio: true,
          imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420);
      await fallback.initialize();
      controller = fallback;
    }
    controller ??= c;
    await controller!.lockCaptureOrientation(
      landscape ? DeviceOrientation.landscapeLeft : DeviceOrientation.portraitUp,
    );
    log('camera ready: ${_description!.name} preview=${controller!.value.previewSize} '
        'requestedFps=${highFps ? 60 : 30} sensor=${_description!.sensorOrientation}° '
        '${landscape ? 'LANDSCAPE' : 'PORTRAIT'} frameRotation=$_frameRotationDeg°');
    final sw = Stopwatch()..start();
    final dump = kDebugMode
        ? p.join((await getApplicationDocumentsDirectory()).path, 'debug_model_input.png')
        : null;
    _runner = await PoseIsolateRunner.spawn(model, debugDumpPath: dump);
    if (dump != null) log('debug: first MoveNet input will be dumped to $dump');
    log('pose isolate ready in ${sw.elapsedMilliseconds} ms (input ${_runner!.inputSize}×${_runner!.inputSize}, ${_runner!.delegateInfo})');
  }

  Future<void> startStreaming() async {
    final c = controller;
    if (c == null || _streaming || _recording) return;
    await c.startImageStream(_onImage);
    _streaming = true;
  }

  Future<void> stopStreaming() async {
    final c = controller;
    if (c == null || !_streaming) return;
    await c.stopImageStream();
    _streaming = false;
  }

  /// Starts video recording while keeping the analysis stream alive.
  Future<void> startRecording() async {
    final c = controller;
    if (c == null || _recording) return;
    await stopStreaming();
    await c.prepareForVideoRecording();
    log('before rec: ${_orientationState(c)}');
    await c.startVideoRecording(onAvailable: _onImage);
    _recording = true;
    log('recording started: ${_orientationState(c)}');
    _formatLogged = false; // log the first recording frame's size/format too
    _rotationFixLogged = false;
  }

  /// Diagnostics for preview rotation during recording (Moto g45 report).
  String _orientationState(CameraController c) {
    final v = c.value;
    return 'device=${v.deviceOrientation.name} locked=${v.lockedCaptureOrientation?.name} '
        'recording=${v.recordingOrientation?.name} previewSize=${v.previewSize} aspect=${v.aspectRatio.toStringAsFixed(3)}';
  }

  Future<XFile?> stopRecording() async {
    final c = controller;
    if (c == null || !_recording) return null;
    _recording = false;
    try {
      final file = await c.stopVideoRecording();
      log('recording stopped: ${file.path} (${await File(file.path).length()} bytes)');
      await startStreaming();
      return file;
    } catch (e) {
      debugPrint('stopVideoRecording failed: $e');
      await startStreaming();
      return null;
    }
  }

  void _onImage(CameraImage image) {
    final t = MonotonicClock.nowMs();
    fps.add(t);
    _received++;
    if (!_formatLogged) {
      _formatLogged = true;
      log('first frame: ${image.width}×${image.height} ${image.format.group.name} planes=${image.planes.length} '
          'rowStride=${image.planes.first.bytesPerRow} pixelStride=${image.planes.length > 1 ? image.planes[1].bytesPerPixel : '-'}');
    }
    if (t - _lastStatMs >= 1000) {
      if (_lastStatMs > 0) {
        final n = _processed == 0 ? 1 : _processed;
        log('cam fps=${fps.fps.toStringAsFixed(1)} recv=$_received processed=$_processed dropped=$_dropped '
            'isolate=${(_inferSum / n).toStringAsFixed(1)}ms pose=${(_poseSum / n).toStringAsFixed(1)}ms (conv=${(_convSum / n).toStringAsFixed(1)} tflite=${(_invokeSum / n).toStringAsFixed(1)}) meanKpScore=${(_kpSum / n).toStringAsFixed(2)}'
            '${_recording ? ' REC' : ''}');
      }
      _received = _dropped = _processed = 0;
      _inferSum = _poseSum = _convSum = _invokeSum = _kpSum = 0;
      _lastStatMs = t;
    }
    final runner = _runner;
    if (runner == null || runner.busy) {
      _dropped++;
      return; // back-pressure: drop
    }
    // Some phones (seen on Moto g45) hand over analysis buffers that are already
    // upright once video recording starts. Rotating those again turns the athlete
    // sideways for the pose model (keypoint scores collapse to ~0.2). Pick the
    // rotation whose output has the orientation this test expects.
    var rotation = _frameRotationDeg;
    final outPortrait = rotation % 180 == 0 ? image.height > image.width : image.width > image.height;
    if (outPortrait == _landscape) {
      rotation = (rotation + 270) % 360;
      if (!_rotationFixLogged) {
        _rotationFixLogged = true;
        log('buffer ${image.width}x${image.height} already rotated${_recording ? ' (REC)' : ''}: '
            'using rotation $rotation° instead of $_frameRotationDeg°');
      }
    }
    final data = CameraFrameData(
      width: image.width,
      height: image.height,
      planes: [for (final pl in image.planes) pl.bytes],
      rowStrides: [for (final pl in image.planes) pl.bytesPerRow],
      pixelStrides: [for (final pl in image.planes) pl.bytesPerPixel ?? 1],
      isBgra: image.format.group == ImageFormatGroup.bgra8888,
      rotationDeg: rotation,
      tMs: t,
      index: _index++,
      mirror: _description?.lensDirection == CameraLensDirection.front,
    );
    runner.process(data, requestFor()).then((r) {
      if (r == null) return;
      _processed++;
      _inferSum += r.inferenceMs;
      _poseSum += r.poseMs;
      _convSum += r.convMs;
      _invokeSum += r.invokeMs;
      _kpSum += r.frame.meanScore;
      onResult?.call(r);
    });
  }

  Future<void> dispose() async {
    _runner?.dispose();
    _runner = null;
    final c = controller;
    controller = null;
    try {
      if (_recording) await c?.stopVideoRecording();
      if (_streaming) await c?.stopImageStream();
    } catch (_) {}
    await c?.dispose();
  }
}

/// Moves a recorded clip into app storage, named and GPS-tagged.
Future<({String path, int size, double? lat, double? lng})> archiveVideo(
  XFile file, {
  required String athleteId,
  required String testId,
}) async {
  final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'videos'));
  await dir.create(recursive: true);
  final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
  final dest = p.join(dir.path, '${athleteId}_${testId}_$ts.mp4');
  final src = File(file.path);
  try {
    await src.rename(dest);
  } on FileSystemException {
    await src.copy(dest);
    await src.delete();
  }
  final pos = await _tryPosition();
  return (path: dest, size: await File(dest).length(), lat: pos?.latitude, lng: pos?.longitude);
}

Future<Position?> _tryPosition() async {
  try {
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    final last = await Geolocator.getLastKnownPosition(forceAndroidLocationManager: true);
    if (last != null) return last;
    return await Geolocator.getCurrentPosition(
      locationSettings: Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.medium,
              forceLocationManager: true, // no Google Play Services dependency
              timeLimit: const Duration(seconds: 3),
            )
          : const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 3)),
    );
  } catch (_) {
    return null;
  }
}
