import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audio/beep.dart';
import '../../core/database/repository.dart';
import '../../core/domain/entities.dart';
import '../../core/domain/sai_test.dart';
import '../../core/localization/l10n.dart';
import '../../core/permissions/permission_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';
import '../../core/widgets/top_status_bar.dart';
import '../../engines/assisted_ocr_engine.dart';
import '../../engines/calibration_engine.dart';
import '../../engines/engine_registry.dart';
import '../../engines/isolate_runner.dart';
import '../../engines/pose_fsm_engine.dart';
import '../../engines/pose_types.dart';
import '../../engines/timing_gate_engine.dart';
import 'camera_pipeline.dart';
import 'confirm_sheet.dart';
import 'hud_painter.dart';
import 'scrubber_sheet.dart';
import 'weight_capture_view.dart';

enum _Stage { loading, calibrate, ready, recording, analysing, done }

class WorkbenchScreen extends ConsumerStatefulWidget {
  const WorkbenchScreen({super.key, required this.athleteId, required this.test});

  final String athleteId;
  final SaiTest test;

  @override
  ConsumerState<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

class _WorkbenchScreenState extends ConsumerState<WorkbenchScreen> with SingleTickerProviderStateMixin {
  SaiTest get test => widget.test;

  _Stage _stage = _Stage.loading;
  Athlete? _athlete;
  int _attemptNo = 1;

  // Source
  bool _simulated = true;
  bool _simForced = true;
  String? _simReason;
  Map<String, Object?> _simReasonParams = const {};
  CameraPipeline? _pipeline;
  Size? _frameSize;

  // Calibration
  StreamSubscription<LevelReading>? _levelSub;
  final _levelNow = ValueNotifier(const LevelReading(0, 0));
  CalibrationResult? _cal;
  List<double> _gateLines = const [];
  bool _wantMarkers = false;
  Completer<List<List<Vec2>>>? _markerWait;

  // Attempt
  MeasurementSession? _session;
  FrameSimulator? _sim;
  late final Ticker _ticker;
  Duration _tickStart = Duration.zero;
  double _simT = 0;
  int _simIndex = 0;
  double _simEpoch = 0;
  final _hud = ValueNotifier(HudFrame.empty);
  final _snap = ValueNotifier(EngineSnapshot.idle);
  final _thumbs = <int, GrayThumb>{};
  bool _finishing = false;

  // Sit-ups "3-2-1-Go": the countdown digit or 'go' shown over the preview.
  final _countdown = ValueNotifier<String?>(null);
  Timer? _goEndTimer;

  /// Age-group window for fixed-duration tests (sit-ups 30 s / 45 s).
  int? get _windowSec => test.durationSecForAge(_athlete?.ageAtRegistration);

  // 2-phone gate
  ClockSyncEngine? _sync;
  GateRole _role = GateRole.finish;
  String _pairCode = ClockSyncEngine.newPairCode();
  SyncResult? _syncResult;
  StreamSubscription<double>? _remoteStartSub;
  bool _startSent = false;
  Timer? _simStartTimer;

  bool get _isGateTest => test.engine == EngineKind.timingGate;
  bool get _twoPhoneFinish => _syncResult != null && _role == GateRole.finish;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    // Landscape tests turn the whole screen, so preview, overlay and video agree.
    if (test.landscape) SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
    _init();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _levelSub?.cancel();
    _activeLevel?.dispose();
    _remoteStartSub?.cancel();
    _simStartTimer?.cancel();
    _goEndTimer?.cancel();
    _countdown.dispose();
    _sync?.dispose();
    _pipeline?.dispose();
    _hud.dispose();
    _snap.dispose();
    _levelNow.dispose();
    if (test.landscape) SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------

  Future<void> _init() async {
    final repo = ref.read(repositoryProvider);
    _athlete = await repo.athlete(widget.athleteId);
    final previous = (await repo.results(widget.athleteId)).where((r) => r.test == test).length;
    _attemptNo = previous + 1;

    if (!test.needsCamera) {
      // Weight: photo-based. Simulation unless the device has a camera to photograph the scale.
      _simulated = true;
      _simForced = false;
      if (mounted) setState(() => _stage = _attemptNo > test.attempts ? _Stage.done : _Stage.ready);
      return;
    }

    CameraPipeline.log('workbench open: ${test.id} athlete=${widget.athleteId} attempt=$_attemptNo');
    final model = await CameraPipeline.loadModel();
    if (model == null) {
      _simForced = true;
      _simReason = 'wb_sim_forced';
    } else {
      final ok = await _startCamera(model);
      _simForced = !ok;
    }
    _simulated = _simForced;
    await _enterCalibrate();
  }

  Future<bool> _startCamera(Uint8List model) async {
    final perm = await ref.read(permissionServiceProvider).request(PermissionGroup.recording);
    CameraPipeline.log('camera permission granted=${perm.granted} permanentlyDenied=${perm.permanentlyDenied}');
    if (!perm.granted) {
      _simReason = 'wb_permission_denied';
      return false;
    }
    unawaited(ref.read(permissionServiceProvider).request(PermissionGroup.location));
    try {
      final p = CameraPipeline();
      await p.init(
        model: model,
        highFps: test == SaiTest.verticalJump || test == SaiTest.broadJump || test == SaiTest.medicineBall || _isGateTest,
        landscape: test.landscape,
      );
      p.onResult = _onCameraResult;
      p.requestFor = () => FrameRequest(
            wantMarkers: _wantMarkers,
            markerCount: test.calibration == CalibrationKind.floorMarkers ? 2 : 1,
            captureBackground: _wantMarkers,
            wantBall: test == SaiTest.medicineBall && _stage == _Stage.recording,
            wantThumb: test == SaiTest.medicineBall && _stage == _Stage.recording,
          );
      await p.startStreaming();
      _pipeline = p;
      return true;
    } catch (e, st) {
      CameraPipeline.log('camera start FAILED: $e\n$st');
      _simReason = 'wb_camera_unavailable';
      _simReasonParams = {'msg': e is CameraException ? e.code : '$e'};
      await _pipeline?.dispose();
      _pipeline = null;
      return false;
    }
  }

  Future<void> _enterCalibrate() async {
    _ticker.stop();
    _session = null;
    _cal = null;
    await _levelSub?.cancel();
    final monitor = _simulated
        ? LevelMonitor(simulated: true)
        : LevelMonitor(simulated: false, landscape: test.landscape);
    _levelSub = monitor.stream.listen((r) => _levelNow.value = r);
    monitor.start();
    // Keep a handle so it is disposed with the screen.
    _replaceLevelMonitor(monitor);

    if (_simulated) {
      _sim = EngineRegistry.createSimulator(test, durationSec: _windowSec);
      _frameSize = Size(_sim!.width, _sim!.height);
      _gateLines = _isGateTest ? (_sim as GateSimulator).gateLinesX : const [];
      _pushIdleHud();
    } else {
      _sim = null;
      final s = _pipeline?.uprightSize;
      _frameSize = s;
      if (_isGateTest && s != null) _gateLines = EngineRegistry.defaultGateLines(test, s.width);
    }
    if (!mounted) return;
    setState(() => _stage = _attemptNo > test.attempts ? _Stage.done : _Stage.calibrate);
    if (test.calibration == CalibrationKind.none && _stage == _Stage.calibrate) await _calibrate();
  }

  LevelMonitor? _activeLevel;
  void _replaceLevelMonitor(LevelMonitor m) {
    _activeLevel?.dispose();
    _activeLevel = m;
  }

  void _pushIdleHud() {
    final sim = _sim;
    if (sim == null) return;
    _hud.value = HudFrame(
      imageWidth: sim.width,
      imageHeight: sim.height,
      frame: sim.frameAt(_idleT(sim), 0),
      scenery: sim.scenery(_idleT(sim)),
      markers: _cal?.markers ?? const [],
      gateLines: _gateLines,
      showGateHandles: _isGateTest && _stage != _Stage.recording,
      simulated: true,
      ballRadiusPx: sim is MedicineBallSimulator ? sim.ballRadiusPx(0.3) : 14,
    );
  }

  /// A representative "ready" moment of the simulation for the idle preview.
  double _idleT(FrameSimulator sim) => sim is GateSimulator ? 0 : (sim.durationMs * 0.3).clamp(0, 1500).toDouble();

  Future<void> _toggleSimulation(bool on) async {
    if (_simForced || _stage == _Stage.recording) return;
    setState(() {
      _simulated = on;
      _stage = _Stage.loading;
    });
    // The live stream would overwrite the simulated HUD and waste CPU: pause it.
    if (_pipeline != null) {
      if (on) {
        await _pipeline!.stopStreaming();
      } else {
        await _pipeline!.startStreaming();
      }
    }
    CameraPipeline.log('demo simulation ${on ? 'ON (camera paused)' : 'OFF (camera live)'}');
    await _enterCalibrate();
  }

  // ---------------------------------------------------------------------------
  // Calibration
  // ---------------------------------------------------------------------------

  bool get _levelOk {
    final kind = test.calibration;
    if (kind == CalibrationKind.none) return true;
    return _levelNow.value.isLevel(requirePitch: kind == CalibrationKind.wallMarker || kind == CalibrationKind.boxScale);
  }

  Future<void> _calibrate() async {
    final l = ref.read(l10nProvider);
    final level = _activeLevel?.last;
    try {
      CalibrationResult cal;
      if (_simulated) {
        cal = EngineRegistry.simulatedCalibration(_sim!, level: level);
      } else {
        final size = _frameSize ?? const Size(720, 1280);
        final quality = CaptureQuality(fps: _pipeline!.fps.fps, width: size.width, height: size.height);
        switch (test.calibration) {
          case CalibrationKind.finishLine:
            cal = EngineRegistry.calibration.forGates(
                linesX: _gateLines, imageWidth: size.width, imageHeight: size.height, level: level, quality: quality);
          case CalibrationKind.none:
            cal = EngineRegistry.calibration.none(imageWidth: size.width, imageHeight: size.height);
          default:
            _markerWait = Completer();
            _wantMarkers = true;
            final markers = await _markerWait!.future.timeout(const Duration(seconds: 4), onTimeout: () => const []);
            _wantMarkers = false;
            cal = EngineRegistry.calibration.fromMarkers(
              kind: test.calibration,
              markers: markers,
              imageWidth: size.width,
              imageHeight: size.height,
              level: level,
              quality: quality,
            );
        }
      }
      CameraPipeline.log('calibrated ${cal.kind.name}: ${cal.toJson()} markers=${cal.markers.length}');
      if (!mounted) return;
      setState(() {
        _cal = cal;
        _stage = _Stage.ready;
      });
      if (_simulated) _pushIdleHud();
    } on CalibrationException catch (e) {
      CameraPipeline.log('calibration failed: ${e.messageKey}');
      _wantMarkers = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.t('wb_calibration_failed', {'msg': l.t(e.messageKey)}))),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Attempt
  // ---------------------------------------------------------------------------

  Future<void> _startAttempt() async {
    if (!await confirmStorageBeforeTest(context, ref)) return;
    var cal = _cal!;
    _thumbs.clear();
    _finishing = false;
    _startSent = false;
    if (_simulated) {
      // Fresh simulated athlete each attempt (re-calibrated: marker placement can depend on stature).
      _sim = EngineRegistry.createSimulator(test, durationSec: _windowSec);
      if (test.calibration != CalibrationKind.none) {
        cal = EngineRegistry.simulatedCalibration(_sim!, level: _activeLevel?.last);
        _cal = cal;
      }
    }
    final athleteHeight = _simulated ? EngineRegistry.simulatedStatureCm(_sim!) : _athlete?.heightCm;
    _session = EngineRegistry.createSession(
      test,
      cal,
      SessionConfig(
        athleteHeightCm: athleteHeight,
        useRemoteStart: _twoPhoneFinish,
        durationSec: _windowSec,
        // Live sit-ups: the timer starts on the assessor's GO beep, not on first sight.
        waitForGo: !_simulated && test == SaiTest.sitUps,
      ),
    );
    _snap.value = EngineSnapshot.idle;
    setState(() => _stage = _Stage.recording);

    // 2-phone: listen for the Start phone's START (already converted to our clock).
    await _remoteStartSub?.cancel();
    if (_twoPhoneFinish) {
      _remoteStartSub = _sync!.remoteStarts.listen((t) => (_session as TimingGateSession?)?.setRemoteStart(t));
    }

    if (_simulated) {
      _simT = 0;
      _simIndex = 0;
      _simEpoch = MonotonicClock.nowMs();
      _tickStart = Duration.zero;
      _ticker.start();
      final peer = _sync?.transport;
      if (_twoPhoneFinish && peer is SimulatedPeerTransport && _sim is GateSimulator) {
        final g = _sim as GateSimulator;
        _simStartTimer = Timer(Duration(milliseconds: (g.startMs / g.timeScale).round()), () {
          peer.emitStart(_simEpoch + g.startMs);
        });
      }
    } else {
      try {
        await _pipeline!.startRecording();
      } catch (e) {
        debugPrint('Recording unavailable, analysing stream only: $e');
      }
      final session = _session;
      if (session is SitUpSession && session.waitForGo) unawaited(_runGoCountdown(session));
    }
  }

  /// "3-2-1-Go" with beeps. The sit-up window starts at the GO beep; the video is
  /// already recording, so the countdown and the beep are in the audit video too.
  Future<void> _runGoCountdown(SitUpSession session) async {
    bool stillLive() => mounted && !_finishing && identical(_session, session);
    for (final n in const ['3', '2', '1']) {
      if (!stillLive()) return;
      _countdown.value = n;
      unawaited(Beep.tick());
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!stillLive()) return;
    final goMs = MonotonicClock.nowMs();
    session.startAt(goMs);
    _countdown.value = 'go';
    unawaited(Beep.go());
    CameraPipeline.log('sit-ups GO at ${goMs.toStringAsFixed(0)} ms, window ${session.durationMs ~/ 1000} s');
    // Safety net: close the window on time even if camera frames stall.
    _goEndTimer?.cancel();
    _goEndTimer = Timer(Duration(milliseconds: session.durationMs.round() + 500), () {
      if (stillLive()) _finishAttempt();
    });
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted && _countdown.value == 'go') _countdown.value = null;
  }

  void _onTick(Duration elapsed) {
    final sim = _sim, session = _session;
    if (sim == null || session == null || _finishing) return;
    if (_tickStart == Duration.zero) _tickStart = elapsed;
    final target = (elapsed - _tickStart).inMicroseconds / 1000 * sim.timeScale;
    final dt = 1000 / sim.fps;
    PoseFrame? last;
    var snap = _snap.value;
    // Simulated 60/120 FPS capture may produce several frames per display tick.
    while (_simT <= target && _simT <= sim.durationMs) {
      final f = sim.frameAt(_simT, _simIndex++);
      final shifted = _twoPhoneFinish
          ? PoseFrame(
              tMs: _simEpoch + f.tMs,
              width: f.width,
              height: f.height,
              keypoints: f.keypoints,
              ball: f.ball,
              silhouetteTop: f.silhouetteTop,
              silhouetteBottom: f.silhouetteBottom,
              index: f.index,
            )
          : f;
      snap = session.process(shifted);
      last = f;
      _simT += dt;
      if (session.isComplete) break;
    }
    if (last != null) {
      _snap.value = snap;
      _hud.value = HudFrame(
        imageWidth: sim.width,
        imageHeight: sim.height,
        frame: last,
        snapshot: snap,
        scenery: sim.scenery(last.tMs),
        simulated: true,
        ballRadiusPx: sim is MedicineBallSimulator ? sim.ballRadiusPx(3) : 14,
      );
    }
    if (session.isComplete || _simT > sim.durationMs) _finishAttempt();
  }

  void _onCameraResult(IsolateResult r) {
    if (!mounted || _simulated) return;
    _frameSize ??= Size(r.frame.width, r.frame.height);
    if (_wantMarkers && _markerWait != null && !_markerWait!.isCompleted) {
      _markerWait!.complete(r.markers);
    }
    if (r.thumb != null && test == SaiTest.medicineBall) {
      _thumbs[r.frame.index] = GrayThumb(r.thumb!, r.thumbWidth, r.thumbHeight);
      if (_thumbs.length > 900) _thumbs.remove(_thumbs.keys.first);
    }
    final session = _session;
    var snap = _snap.value;
    if (session != null && _stage == _Stage.recording && !_finishing) {
      snap = session.process(r.frame);
      _snap.value = snap;
      // Start phone: forward our detected start to the Finish phone.
      if (_syncResult != null && _role == GateRole.start && !_startSent) {
        final s = (session as TimingGateSession).startMs;
        if (s != null) {
          _startSent = true;
          _sync!.sendStart(s);
        }
      }
      if (session.isComplete) _finishAttempt();
    }
    _hud.value = HudFrame(
      imageWidth: r.frame.width,
      imageHeight: r.frame.height,
      frame: r.frame,
      snapshot: snap,
      markers: _stage == _Stage.recording ? const [] : (_cal?.markers ?? r.markers),
      gateLines: _gateLines,
      showGateHandles: _isGateTest && _stage != _Stage.recording,
    );
  }

  Future<void> _finishAttempt() async {
    if (_finishing) return;
    _finishing = true;
    _ticker.stop();
    _simStartTimer?.cancel();
    _goEndTimer?.cancel();
    _countdown.value = null;
    setState(() => _stage = _Stage.analysing);

    XFile? video;
    if (!_simulated) video = await _pipeline?.stopRecording();

    final session = _session!;
    var outcome = session.finalize();
    CameraPipeline.log('attempt ${test.id} #$_attemptNo → value=${outcome.value} conf=${outcome.confidence.round()} '
        'fouls=${outcome.fouls} simulated=$_simulated video=${video?.path}');
    final truth = _sim?.groundTruth ?? const <String, Object?>{};

    if (outcome.requiresScrub && session is MedicineBallSession && session.proposedIndex != null && mounted) {
      final sim = _sim;
      final picked = await showLandingScrubber(
        context,
        session: session,
        scenery: (t) => sim?.scenery(t) ?? const [],
        simulated: _simulated,
        ballRadiusPx: sim is MedicineBallSimulator ? sim.ballRadiusPx(3) : 10,
        thumbs: _thumbs,
      );
      if (picked != null) outcome = session.confirmLanding(picked.$1, picked.$2);
    }
    if (!mounted) return;
    await _review(outcome, truth, video: video);
  }

  Future<void> _review(AttemptOutcome outcome, Map<String, Object?> truth, {XFile? video, double? bmiValue}) async {
    final l = ref.read(l10nProvider);
    final decision = await showConfirmSheet(
      context,
      outcome: outcome,
      attemptNo: _attemptNo,
      groundTruth: truth,
      simulated: _simulated,
      bmiValue: bmiValue ?? (outcome.metadata['bmi'] as num?)?.toDouble(),
    );
    if (!mounted) return;
    if (decision == null || decision.action == ConfirmAction.discard) {
      if (video != null) {
        try {
          await File(video.path).delete();
        } catch (_) {}
      }
      setState(() => _stage = _Stage.ready);
      if (_simulated && test.needsCamera) _pushIdleHud();
      return;
    }
    await _save(outcome, decision, truth, video);
    if (!mounted) return;
    final value = decision.value!;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(decision.action == ConfirmAction.override
          ? l.t('sheet_override_logged')
          : l.t('sheet_saved', {'value': '${test.format(value)} ${l.unit(test)}'})),
    ));
    ref.invalidate(freeStorageProvider);
    setState(() {
      _attemptNo++;
      _stage = _attemptNo > test.attempts ? _Stage.done : _Stage.ready;
    });
    if (_simulated && test.needsCamera) _pushIdleHud();
  }

  Future<void> _save(AttemptOutcome o, ConfirmDecision d, Map<String, Object?> truth, XFile? video) async {
    final isOverride = d.action == ConfirmAction.override;
    final resultId = newId('r_');
    final now = DateTime.now();
    final result = TestResult(
      id: resultId,
      athleteId: widget.athleteId,
      test: test,
      attemptNo: _attemptNo,
      aiScore: o.value,
      finalScore: d.value!,
      confidence: isOverride ? 100 : o.confidence,
      isOverride: isOverride,
      simulated: _simulated,
      createdAt: now,
      metadata: {
        ...o.metadata,
        'fouls': o.fouls,
        'aiConfidence': o.confidence.round(),
        if (truth.isNotEmpty) 'simGroundTruth': truth,
      },
    );
    final label = isOverride
        ? TrainingLabel(
            id: newId('t_'),
            resultId: resultId,
            test: test,
            aiScore: o.value,
            manualScore: d.value!,
            reason: d.reason ?? 'unspecified',
            features: o.metadata,
            createdAt: now,
          )
        : null;
    VideoRecord? videoRecord;
    if (video != null) {
      try {
        final a = await archiveVideo(video, athleteId: widget.athleteId, testId: test.id);
        videoRecord = VideoRecord(
          id: newId('v_'),
          athleteId: widget.athleteId,
          test: test,
          resultId: resultId,
          filePath: a.path,
          sizeBytes: a.size,
          recordedAt: now,
          lat: a.lat,
          lng: a.lng,
        );
      } catch (e) {
        debugPrint('Video archive failed: $e');
      }
    }
    await ref.read(repositoryProvider).saveAttempt(result: result, label: label, video: videoRecord);
  }

  // ---------------------------------------------------------------------------
  // 2-phone pairing
  // ---------------------------------------------------------------------------

  Future<void> _pair(String code) async {
    final l = ref.read(l10nProvider);
    try {
      await _sync?.dispose();
      if (_simulated) {
        _sync = ClockSyncEngine(SimulatedPeerTransport());
      } else {
        await ref.read(permissionServiceProvider).request(PermissionGroup.nearbyDevices);
        _sync = ClockSyncEngine(await UdpSyncTransport.open());
      }
      if (_role == GateRole.start) {
        _sync!.hostAsStart(code);
        setState(() => _syncResult = const SyncResult(offsetMs: 0, rttMs: 0, samples: 0));
      } else {
        final r = await _sync!.pairAsFinish(code);
        if (mounted) setState(() => _syncResult = r);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _syncResult = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('wb_pair_failed', {'msg': e}))));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(l10nProvider);
    final simBanner = _simReason != null && _simulated
        ? Container(
            width: double.infinity,
            color: AppColors.warning,
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: 6),
            child: Text(
              l.t(_simReason!, _simReasonParams),
              style: const TextStyle(color: AppColors.text, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          )
        : null;

    // Landscape tests: camera on the left, controls in a side panel on the right.
    if (test.landscape && MediaQuery.orientationOf(context) == Orientation.landscape) {
      return Scaffold(
        backgroundColor: AppColors.hudBackdrop,
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  children: [
                    _header(l),
                    ?simBanner,
                    Expanded(child: _viewport(l)),
                  ],
                ),
              ),
              SizedBox(
                width: (MediaQuery.sizeOf(context).width * 0.36).clamp(280.0, 380.0),
                child: _bottomPanel(l, side: true),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.hudBackdrop,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const TopStatusBar(dark: true),
            _header(l),
            ?simBanner,
            Expanded(
              child: test.needsCamera
                  ? _viewport(l)
                  : WeightCaptureView(
                      simulated: _simulated,
                      heightCm: _athlete?.heightCm,
                      onOutcome: (o, truth) => _review(o, truth),
                    ),
            ),
            if (test.needsCamera || _stage == _Stage.done) _bottomPanel(l),
          ],
        ),
      ),
    );
  }

  Widget _header(L10n l) => Container(
        color: AppColors.hudBackdrop,
        padding: const EdgeInsets.only(right: AppSpace.sm),
        child: Row(
          children: [
            IconButton(
              color: Colors.white,
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => context.pop(),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.testName(test),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${_athlete?.name ?? ''} · #${_attemptNo.clamp(1, test.attempts)}/${test.attempts}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.metricS.copyWith(color: Colors.white60),
                  ),
                ],
              ),
            ),
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      l.t('wb_simulation'),
                      textAlign: TextAlign.end,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Switch(
                    value: _simulated,
                    onChanged: _simForced || _stage == _Stage.recording || _stage == _Stage.analysing
                        ? null
                        : _toggleSimulation,
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _viewport(L10n l) {
    if (_stage == _Stage.loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    final size = _frameSize ?? const Size(720, 1280);
    final controller = _pipeline?.controller;
    final showCamera = !_simulated && controller != null && controller.value.isInitialized;
    final aspect = size.width / size.height;

    return Stack(
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: aspect,
            child: LayoutBuilder(
              builder: (context, c) => GestureDetector(
                // Drag the virtual gate line(s) before recording (live camera only:
                // simulated gates sit exactly on the simulator's world lines).
                onHorizontalDragUpdate: _isGateTest && !_simulated && _stage != _Stage.recording
                    ? (d) {
                        final tf = HudTransform(c.biggest, size.width, size.height);
                        final x = tf.unmap(d.localPosition).x.clamp(0.0, size.width);
                        final lines = [..._gateLines];
                        var nearest = 0;
                        for (var i = 1; i < lines.length; i++) {
                          if ((lines[i] - x).abs() < (lines[nearest] - x).abs()) nearest = i;
                        }
                        lines[nearest] = x;
                        setState(() => _gateLines = lines);
                        _cal = null;
                        if (_stage == _Stage.ready) _stage = _Stage.calibrate;
                      }
                    : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (showCamera) CameraPreview(controller),
                    CustomPaint(painter: HudPainter(_hud)),
                    IgnorePointer(
                      child: ValueListenableBuilder<String?>(
                        valueListenable: _countdown,
                        builder: (_, v, _) => v == null
                            ? const SizedBox.shrink()
                            : Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    borderRadius: BorderRadius.circular(AppSpace.radius),
                                  ),
                                  child: Text(
                                    v == 'go' ? l.t('wb_go') : v,
                                    style: AppText.metricXL.copyWith(
                                      color: v == 'go' ? AppColors.pass : Colors.white,
                                      fontSize: 96,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(left: AppSpace.sm, top: AppSpace.sm, right: AppSpace.sm, child: _liveReadout(l)),
      ],
    );
  }

  Widget _liveReadout(L10n l) => ValueListenableBuilder<EngineSnapshot>(
        valueListenable: _snap,
        builder: (_, s, _) {
          final recording = _stage == _Stage.recording || _stage == _Stage.analysing;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    recording ? l.t(s.phaseKey, s.phaseParams) : l.t(_stageLabel()),
                    maxLines: 2,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              if (recording && s.primary != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(s.primary!, style: AppText.metricL.copyWith(color: Colors.white)),
                      if (s.primaryLabelKey != null || s.secondary != null)
                        Text(
                          [if (s.primaryLabelKey != null) l.t(s.primaryLabelKey!), ?s.secondary].join(' · '),
                          style: AppText.metricS.copyWith(color: Colors.white70),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      );

  String _stageLabel() => switch (_stage) {
        _Stage.calibrate => 'wb_step_calibrate',
        _Stage.ready => 'phase_idle',
        _Stage.done => 'wb_all_attempts_done',
        _ => 'loading',
      };

  /// Controls panel: along the bottom in portrait, full-height on the right ([side]) in landscape.
  Widget _bottomPanel(L10n l, {bool side = false}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: side
            ? const BorderRadius.horizontal(left: Radius.circular(16))
            : const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: side ? null : BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.46),
      child: SafeArea(
        top: side,
        left: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.md, AppSpace.md, AppSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: switch (_stage) {
              _Stage.loading => [const LinearProgressIndicator()],
              _Stage.calibrate => _calibratePanel(l),
              _Stage.ready => _readyPanel(l),
              _Stage.recording => _recordingPanel(l),
              _Stage.analysing => [const LinearProgressIndicator(), const SizedBox(height: 52)],
              _Stage.done => [
                  Row(
                    children: [
                      const Icon(Icons.check_circle_rounded, color: AppColors.pass, size: 28),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(child: Text(l.t('wb_all_attempts_done'), style: Theme.of(context).textTheme.titleMedium)),
                    ],
                  ),
                  const SizedBox(height: AppSpace.md),
                  PrimaryButton(label: l.t('done'), icon: Icons.arrow_back_rounded, onPressed: () => context.pop()),
                ],
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _calibratePanel(L10n l) => [
        Text(l.t(test.setupKey), style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        const SizedBox(height: AppSpace.sm),
        ValueListenableBuilder<LevelReading>(
          valueListenable: _levelNow,
          builder: (_, r, _) => _QualityChips(
            reading: r,
            requirePitch: test.calibration == CalibrationKind.wallMarker || test.calibration == CalibrationKind.boxScale,
            fps: _simulated ? (_sim?.fps ?? 30) : (_pipeline?.fps.fps ?? 0),
            frameSize: _frameSize,
            needsLevel: test.calibration != CalibrationKind.none,
          ),
        ),
        if (_isGateTest && test != SaiTest.enduranceRun) ...[
          const SizedBox(height: AppSpace.sm),
          _TwoPhonePanel(
            role: _role,
            code: _pairCode,
            result: _syncResult,
            onRole: (r) => setState(() {
              _role = r;
              _syncResult = null;
              if (r == GateRole.start) _pairCode = ClockSyncEngine.newPairCode();
            }),
            onPair: _pair,
          ),
        ],
        if (_isGateTest && !_simulated)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(l.t('wb_place_line'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ),
        const SizedBox(height: AppSpace.md),
        ValueListenableBuilder<LevelReading>(
          valueListenable: _levelNow,
          builder: (_, _, _) => PrimaryButton(
            label: _levelOk ? l.t('wb_calibrate_btn') : l.t('wb_phone_level_warn'),
            icon: Icons.center_focus_strong_rounded,
            onPressed: _levelOk ? _calibrate : null,
          ),
        ),
      ];

  List<Widget> _readyPanel(L10n l) => [
        if (_cal != null && _cal!.kind != CalibrationKind.none)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                StatusPill(
                  label: _cal!.kind == CalibrationKind.finishLine
                      ? l.t('wb_line_set')
                      : l.t('wb_calibrated', {'ppc': _cal!.pixelsPerCm.toStringAsFixed(2)}),
                  color: AppColors.pass,
                  icon: Icons.check_rounded,
                ),
                ConfidenceBadge(confidence: _cal!.confidence, compact: true),
                if (_syncResult != null && _role == GateRole.finish)
                  StatusPill(
                    label: l.t('wb_sync_offset', {'ms': _syncResult!.offsetMs.toStringAsFixed(1)}),
                    color: AppColors.primary,
                    icon: Icons.sync_rounded,
                  ),
              ],
            ),
          ),
        Text(l.t(test.setupKey), style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
        const SizedBox(height: AppSpace.md),
        Row(
          children: [
            if (test.calibration != CalibrationKind.none)
              Padding(
                padding: const EdgeInsets.only(right: AppSpace.sm),
                child: IconButton.outlined(
                  tooltip: l.t('wb_step_calibrate'),
                  onPressed: () => setState(() => _stage = _Stage.calibrate),
                  icon: const Icon(Icons.tune_rounded),
                ),
              ),
            Expanded(
              child: PrimaryButton(
                label: l.t('wb_start_attempt', {'n': _attemptNo}),
                icon: _simulated ? Icons.play_arrow_rounded : Icons.fiber_manual_record_rounded,
                color: _simulated ? null : AppColors.foul,
                onPressed: _startAttempt,
              ),
            ),
          ],
        ),
      ];

  List<Widget> _recordingPanel(L10n l) => [
        ValueListenableBuilder<EngineSnapshot>(
          valueListenable: _snap,
          builder: (_, s, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (s.progress != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: s.progress!.clamp(0.0, 1.0), minHeight: 8),
                ),
              const SizedBox(height: AppSpace.sm),
              if (s.fouls.isEmpty)
                Text(l.t('wb_fouls', {'n': 0}), style: AppText.metricS)
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in _countFouls(s.fouls).entries)
                      StatusPill(label: '${l.t(e.key)} ×${e.value}', color: AppColors.foul, icon: Icons.flag_outlined),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.md),
        PrimaryButton(
          label: l.t('wb_stop_attempt'),
          icon: Icons.stop_rounded,
          color: AppColors.text,
          onPressed: _finishAttempt,
        ),
      ];

  Map<String, int> _countFouls(List<String> fouls) {
    final m = <String, int>{};
    for (final f in fouls) {
      m[f] = (m[f] ?? 0) + 1;
    }
    return m;
  }
}

class _QualityChips extends ConsumerWidget {
  const _QualityChips({
    required this.reading,
    required this.requirePitch,
    required this.fps,
    required this.frameSize,
    required this.needsLevel,
  });

  final LevelReading reading;
  final bool requirePitch;
  final double fps;
  final Size? frameSize;
  final bool needsLevel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final level = reading.isLevel(requirePitch: requirePitch);
    final deg = reading.worstDeg(requirePitch: requirePitch).toStringAsFixed(1);
    final q = CaptureQuality(fps: fps, width: frameSize?.width ?? 0, height: frameSize?.height ?? 0);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (needsLevel)
          StatusPill(
            label: l.t(level ? 'cal_level_ok' : 'cal_level_bad', {'deg': deg}),
            color: level ? AppColors.pass : AppColors.warning,
            icon: Icons.straighten_rounded,
          ),
        StatusPill(
          label: q.fpsOk ? '${fps.round()} ${l.t('wb_fps')}' : l.t('cal_fps_low'),
          color: q.fpsOk ? (q.fpsOptimal ? AppColors.pass : AppColors.primary) : AppColors.warning,
          icon: Icons.speed_rounded,
        ),
        if (frameSize != null)
          StatusPill(
            label: q.resolutionOk ? q.resolutionLabel : l.t('cal_res_low'),
            color: q.resolutionOk ? AppColors.pass : AppColors.warning,
            icon: Icons.high_quality_outlined,
          ),
      ],
    );
  }
}

class _TwoPhonePanel extends ConsumerStatefulWidget {
  const _TwoPhonePanel({
    required this.role,
    required this.code,
    required this.result,
    required this.onRole,
    required this.onPair,
  });

  final GateRole role;
  final String code;
  final SyncResult? result;
  final ValueChanged<GateRole> onRole;
  final Future<void> Function(String code) onPair;

  @override
  ConsumerState<_TwoPhonePanel> createState() => _TwoPhonePanelState();
}

class _TwoPhonePanelState extends ConsumerState<_TwoPhonePanel> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(l10nProvider);
    final r = widget.result;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading: const Icon(Icons.phonelink_ring_outlined, color: AppColors.primary),
        title: Text(l.t('wb_two_phone'), style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: r == null || widget.role == GateRole.start
            ? null
            : Text(l.t('wb_pair_ok', {'ms': r.offsetMs.toStringAsFixed(1), 'rtt': r.rttMs.toStringAsFixed(1)}),
                style: AppText.metricS.copyWith(color: AppColors.pass)),
        children: [
          Text(l.t('wb_pair_help'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: AppSpace.sm),
          SegmentedButton<GateRole>(
            segments: [
              ButtonSegment(value: GateRole.start, label: Text(l.t('wb_pair_start'))),
              ButtonSegment(value: GateRole.finish, label: Text(l.t('wb_pair_finish'))),
            ],
            selected: {widget.role},
            onSelectionChanged: (s) => widget.onRole(s.first),
          ),
          const SizedBox(height: AppSpace.sm),
          if (widget.role == GateRole.start)
            Row(
              children: [
                Text('${l.t('wb_pair_code')}: ', style: const TextStyle(color: AppColors.textMuted)),
                Text(widget.code, style: AppText.metricL.copyWith(letterSpacing: 6)),
              ],
            )
          else
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 4,
              style: AppText.metricM.copyWith(letterSpacing: 6),
              decoration: InputDecoration(labelText: l.t('wb_pair_code'), counterText: ''),
            ),
          const SizedBox(height: AppSpace.sm),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final code = widget.role == GateRole.start ? widget.code : _code.text.trim();
                    if (code.length != 4) return;
                    setState(() => _busy = true);
                    await widget.onPair(code);
                    if (mounted) setState(() => _busy = false);
                  },
            icon: _busy
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync_rounded),
            label: Text(l.t('wb_pair_connect')),
          ),
          const SizedBox(height: AppSpace.sm),
        ],
      ),
    );
  }
}
