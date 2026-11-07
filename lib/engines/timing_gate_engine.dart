/// Module D: Virtual timing gates — 30 m Sprint, 4×10 m Shuttle, Endurance Run.
///
/// Single-phone: the timer starts on the athlete's first movement (back-dated
/// by fitting the initial constant-acceleration displacement d = a·(t−t₀)²)
/// and stops when the **torso midpoint** (mean of shoulders + hips) crosses the
/// virtual line; outstretched arms or a dipping head are ignored. Crossing time
/// is interpolated between frames.
///
/// 2-phone (offline): Start and Finish/Turn phones pair over local Wi-Fi or a
/// hotspot via UDP with a 4-digit code (no internet), estimate their clock
/// offset NTP-style, and exchange START / TOUCH events.
///
/// Simulation Mode: [GateSimulator] animates a running athlete with gait,
/// lean, a finish-line dip and (for the shuttle) occasional missed line
/// touches; [SimulatedPeerTransport] emulates the second phone with a skewed
/// clock and asymmetric network latency.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../core/domain/sai_test.dart';
import 'pose_types.dart';

/// Shared monotonic clock for frame timestamps and clock sync.
abstract final class MonotonicClock {
  static final Stopwatch _sw = Stopwatch()..start();
  static double nowMs() => _sw.elapsedMicroseconds / 1000.0;
}

// ---------------------------------------------------------------------------
// Gate session
// ---------------------------------------------------------------------------

enum GateMode { sprint, shuttle, endurance }

enum _GatePhase { waitingAthlete, armed, running, finished }

class ShuttleLeg {
  ShuttleLeg(this.index);
  final int index;
  double? endMs;
  bool touched = false;
  double maxPenetrationPx = -1e9;

  Map<String, Object?> toJson() => {
        'leg': index + 1,
        'endMs': endMs?.round(),
        'touched': touched,
      };
}

class TimingGateSession implements MeasurementSession {
  TimingGateSession({
    required this.test,
    required this.linesX,
    required this.imageWidth,
    this.totalLaps = 4,
    this.minLapMs = 20000,
    this.useRemoteStart = false,
  }) : mode = switch (test) {
          SaiTest.sprint30m => GateMode.sprint,
          SaiTest.shuttleRun => GateMode.shuttle,
          SaiTest.enduranceRun => GateMode.endurance,
          _ => throw ArgumentError('${test.id} is not a timing-gate test'),
        };

  @override
  final SaiTest test;
  final GateMode mode;

  /// Sprint/endurance: [finish]. Shuttle: [lineA (start/finish), lineB (turn)].
  final List<double> linesX;
  final double imageWidth;
  final int totalLaps;
  final double minLapMs;

  /// 2-phone mode: start time comes from the Start phone, not local motion.
  final bool useRemoteStart;

  _GatePhase _phase = _GatePhase.waitingAthlete;
  final _baseline = <Vec2>[];
  Vec2? _basePos;
  int _movingRun = 0;
  double? _startMs;
  bool _startRefined = false;
  final _armedHistory = <(double, double)>[]; // (t, torso displacement px) while armed
  double? _finishMs;
  Vec2? _prevTorso;
  double? _prevT;
  int _dir = 1;
  final _scores = <double>[];
  final _fouls = <String>[];
  double _lastT = 0;
  Vec2? _torso;
  final _torsoNoise = <double>[];

  // Shuttle
  final legs = <ShuttleLeg>[];
  final _xHistory = <(double, double)>[];

  // Endurance
  final lapTimes = <double>[];
  double? _lastLapMs;

  double get _moveThresholdPx => math.max(imageWidth * 0.006, 4.0);

  @override
  bool get isComplete => _phase == _GatePhase.finished;

  double? get startMs => _startMs;

  /// 2-phone: Start phone's START event, already converted to this phone's clock.
  void setRemoteStart(double localStartMs) {
    _startMs = localStartMs;
    _startRefined = true;
    if (_phase != _GatePhase.finished) _phase = _GatePhase.running;
  }

  @override
  EngineSnapshot process(PoseFrame f) {
    _lastT = f.tMs;
    if (isComplete) return _snap(f);
    if (!f.hasPerson) {
      _prevTorso = null; // no interpolation across gaps
      return _snap(f);
    }
    final torso = f.torsoCenter;
    _torso = torso;
    _scores.add(f.scoreOf([KP.leftShoulder, KP.rightShoulder, KP.leftHip, KP.rightHip]));

    switch (_phase) {
      case _GatePhase.waitingAthlete:
        _baseline.add(torso);
        if (_baseline.length >= 10) {
          _basePos = Vec2(median(_baseline.map((p) => p.x).toList()), median(_baseline.map((p) => p.y).toList()));
          for (final p in _baseline) {
            _torsoNoise.add(p.distanceTo(_basePos!));
          }
          _phase = _GatePhase.armed;
          final target = mode == GateMode.shuttle ? linesX[1] : linesX[0];
          _dir = target >= _basePos!.x ? 1 : -1;
          if (mode == GateMode.endurance) _dir = 0; // decided by first movement
          if (useRemoteStart && _startMs != null) _phase = _GatePhase.running;
        }
      case _GatePhase.armed:
        if (useRemoteStart) break;
        final d = (torso - _basePos!).length;
        _armedHistory.add((f.tMs, d));
        if (_armedHistory.length > 240) _armedHistory.removeAt(0);
        _movingRun = d > _moveThresholdPx ? _movingRun + 1 : 0;
        if (_movingRun >= 2) {
          _startMs = f.tMs;
          _backdateStart();
          _startRefined = true;
          _phase = _GatePhase.running;
          if (_dir == 0) _dir = torso.x >= _basePos!.x ? 1 : -1;
        }
      case _GatePhase.running:
        switch (mode) {
          case GateMode.sprint:
            _checkFinish(f, torso, linesX[0], _dir);
          case GateMode.shuttle:
            _shuttle(f, torso);
          case GateMode.endurance:
            _endurance(f, torso);
        }
      case _GatePhase.finished:
        break;
    }
    _prevTorso = torso;
    _prevT = f.tMs;
    return _snap(f);
  }

  /// "First movement": walk back from the detection frame to where the torso
  /// displacement last sat inside the standing-still noise floor, and
  /// interpolate the exit time.
  void _backdateStart() {
    final noise = _torsoNoise.isEmpty ? 1.0 : mean(_torsoNoise) + 3 * stdDev(_torsoNoise) + 0.3;
    var j = _armedHistory.length - 1;
    while (j > 0 && _armedHistory[j - 1].$2 > noise) {
      j--;
    }
    if (j <= 0) return;
    final (t0, d0) = _armedHistory[j - 1];
    final (t1, d1) = _armedHistory[j];
    final frac = d1 == d0 ? 0.0 : ((noise - d0) / (d1 - d0)).clamp(0.0, 1.0);
    final t = t0 + (t1 - t0) * frac;
    if (t <= _startMs! && _startMs! - t < 600) _startMs = t;
  }

  bool _crossed(double x, double prevX, double line, int dir) =>
      (prevX - line) * dir < 0 && (x - line) * dir >= 0;

  double _crossTime(double x, double prevX, double line, double t, double prevT) {
    final frac = ((line - prevX) / (x - prevX)).clamp(0.0, 1.0);
    return prevT + (t - prevT) * frac;
  }

  void _checkFinish(PoseFrame f, Vec2 torso, double line, int dir) {
    if (_prevTorso == null || _prevT == null) return;
    if (_crossed(torso.x, _prevTorso!.x, line, dir)) {
      _finishMs = _crossTime(torso.x, _prevTorso!.x, line, f.tMs, _prevT!);
      _phase = _GatePhase.finished;
    }
  }

  void _shuttle(PoseFrame f, Vec2 torso) {
    final a = linesX[0], b = linesX[1];
    final spacing = (b - a).abs();
    if (legs.isEmpty) legs.add(ShuttleLeg(0));
    final leg = legs.last;
    final target = leg.index.isEven ? b : a;
    final dir = (target - (leg.index.isEven ? a : b)).sign.toInt();

    if (leg.index == 3) {
      _checkFinish(f, torso, a, dir);
      if (_finishMs != null) {
        leg.endMs = _finishMs;
        leg.touched = true;
      }
      return;
    }
    // Furthest ankle past the target line (line touch).
    final pen = math.max(
      (f[KP.leftAnkle].p.x - target) * dir,
      (f[KP.rightAnkle].p.x - target) * dir,
    );
    if (f[KP.leftAnkle].score > 0.3 || f[KP.rightAnkle].score > 0.3) {
      leg.maxPenetrationPx = math.max(leg.maxPenetrationPx, pen);
    }
    _xHistory.add((f.tMs, torso.x));
    if (_xHistory.length > 6) _xHistory.removeAt(0);
    final nearTarget = (torso.x - target).abs() < spacing * 0.3;
    if (nearTarget && _xHistory.length == 6) {
      final v = (_xHistory.last.$2 - _xHistory.first.$2) * dir;
      // Torso now moving away from the target: the turn happened.
      if (v < -_moveThresholdPx) {
        leg.endMs = _xHistory.first.$1;
        leg.touched = leg.maxPenetrationPx >= -imageWidth * 0.005;
        if (!leg.touched) _fouls.add('foul_line_not_touched');
        legs.add(ShuttleLeg(leg.index + 1));
        _xHistory.clear();
      }
    }
  }

  void _endurance(PoseFrame f, Vec2 torso) {
    if (_prevTorso == null || _prevT == null) return;
    final line = linesX[0];
    if (_crossed(torso.x, _prevTorso!.x, line, _dir)) {
      final t = _crossTime(torso.x, _prevTorso!.x, line, f.tMs, _prevT!);
      final since = t - (_lastLapMs ?? _startMs!);
      if (since >= minLapMs) {
        lapTimes.add(t);
        _lastLapMs = t;
        if (lapTimes.length >= totalLaps) {
          _finishMs = t;
          _phase = _GatePhase.finished;
        }
      }
    }
  }

  double? get elapsedMs {
    if (_startMs == null) return null;
    return (_finishMs ?? _lastT) - _startMs!;
  }

  EngineSnapshot _snap(PoseFrame f) {
    final overlay = <HudPrimitive>[
      for (var i = 0; i < linesX.length; i++)
        HudLine(Vec2(linesX[i], 0), Vec2(linesX[i], f.height),
            tone: i == 0 ? (isComplete ? HudTone.pass : HudTone.warning) : HudTone.primary,
            width: 3,
            label: mode == GateMode.shuttle ? (i == 0 ? 'A' : 'B') : 'FINISH'),
      if (_torso != null) HudPoint(_torso!, tone: HudTone.pass, radius: 9, label: 'torso'),
    ];
    final secs = elapsedMs == null ? null : elapsedMs! / 1000;
    final secondary = switch (mode) {
      GateMode.shuttle => 'legs:${legs.where((l) => l.endMs != null).length}',
      GateMode.endurance => 'laps:${lapTimes.length}/$totalLaps',
      GateMode.sprint => null,
    };
    return EngineSnapshot(
      phaseKey: switch (_phase) {
        _GatePhase.waitingAthlete => 'wb_waiting',
        _GatePhase.armed => 'phase_armed',
        _GatePhase.running => 'phase_running',
        _GatePhase.finished => 'phase_finished',
      },
      primary: secs == null ? '0.00' : test.format(secs),
      primaryLabelKey: 'units_s',
      secondary: secondary,
      overlay: overlay,
      fouls: List.unmodifiable(_fouls),
      complete: isComplete,
    );
  }

  @override
  AttemptOutcome finalize() {
    final elapsed = _finishMs != null && _startMs != null ? (_finishMs! - _startMs!) / 1000 : null;
    final kp = _scores.isEmpty ? 0.0 : mean(_scores);
    final missedTouches = legs.where((l) => l.endMs != null && !l.touched).length;
    var conf = (kp.clamp(0.0, 1.0) * 100 * 0.6 + 38).clamp(0.0, 99.0);
    if (!_startRefined && !useRemoteStart) conf -= 10;
    if (missedTouches > 0) conf -= 15;
    return AttemptOutcome(
      test: test,
      value: elapsed,
      confidence: elapsed == null ? 0 : conf.clamp(5, 99),
      fouls: {..._fouls}.toList(),
      metadata: {
        'mode': useRemoteStart ? 'two_phone' : 'single_phone',
        'startMs': _startMs?.round(),
        'finishMs': _finishMs?.round(),
        if (mode == GateMode.shuttle) 'legs': legs.map((l) => l.toJson()).toList(),
        if (mode == GateMode.shuttle) 'missedTouches': missedTouches,
        if (mode == GateMode.endurance)
          'lapSplitsS': [
            for (var i = 0; i < lapTimes.length; i++)
              double.parse(((lapTimes[i] - (i == 0 ? _startMs! : lapTimes[i - 1])) / 1000).toStringAsFixed(1)),
          ],
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Offline 2-phone clock sync
// ---------------------------------------------------------------------------

enum GateRole { start, finish }

class SyncMessage {
  const SyncMessage(this.data, this.receivedAtMs, [this.from]);
  final Map<String, Object?> data;
  final double receivedAtMs;
  final InternetAddress? from;
  String get type => data['type'] as String? ?? '';
}

abstract class SyncTransport {
  Stream<SyncMessage> get incoming;
  Future<void> send(Map<String, Object?> msg);
  Future<void> close();
}

/// UDP broadcast/unicast on the local network (Wi-Fi or phone hotspot). No internet.
class UdpSyncTransport implements SyncTransport {
  UdpSyncTransport._(this._socket);

  static const port = 47474;
  final RawDatagramSocket _socket;
  InternetAddress? _peer;
  final _controller = StreamController<SyncMessage>.broadcast();

  static Future<UdpSyncTransport> open() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    socket.broadcastEnabled = true;
    final t = UdpSyncTransport._(socket);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      final at = MonotonicClock.nowMs();
      try {
        final data = (jsonDecode(utf8.decode(dg.data)) as Map).cast<String, Object?>();
        if (data['app'] != 'athletesetu') return;
        t._peer ??= dg.address;
        t._controller.add(SyncMessage(data, at, dg.address));
      } catch (_) {
        // Not ours.
      }
    });
    return t;
  }

  @override
  Stream<SyncMessage> get incoming => _controller.stream;

  @override
  Future<void> send(Map<String, Object?> msg) async {
    final bytes = utf8.encode(jsonEncode({...msg, 'app': 'athletesetu'}));
    _socket.send(bytes, _peer ?? InternetAddress('255.255.255.255'), port);
  }

  @override
  Future<void> close() async {
    _socket.close();
    await _controller.close();
  }
}

/// In-process emulation of the other phone: its clock runs [skewMs] ahead with
/// [driftPpm] drift, and each direction has independent random latency.
class SimulatedPeerTransport implements SyncTransport {
  SimulatedPeerTransport({int seed = 99, double? skewMs, this.driftPpm = 25})
      : _noise = SimNoise(seed),
        skewMs = skewMs ?? 2000 + SimNoise(seed).uniform(0, 4000);

  final SimNoise _noise;
  final double skewMs;
  final double driftPpm;
  final _controller = StreamController<SyncMessage>.broadcast();
  bool _closed = false;

  double _remoteNow() {
    final l = MonotonicClock.nowMs();
    return l + skewMs + l * driftPpm / 1e6;
  }

  double _latency() => 3 + _noise.uniform(0, 1) * _noise.uniform(0, 1) * 30;

  @override
  Stream<SyncMessage> get incoming => _controller.stream;

  void _deliver(Map<String, Object?> data, double delayMs) {
    Timer(Duration(microseconds: (delayMs * 1000).round()), () {
      if (_closed) return;
      _controller.add(SyncMessage(data, MonotonicClock.nowMs()));
    });
  }

  @override
  Future<void> send(Map<String, Object?> msg) async {
    final up = _latency();
    // The emulated Start phone handles the message after the uplink delay.
    Timer(Duration(microseconds: (up * 1000).round()), () {
      if (_closed) return;
      switch (msg['type']) {
        case 'HELLO':
          _deliver({'type': 'WELCOME', 'code': msg['code']}, _latency());
        case 'PING':
          final t1 = _remoteNow();
          final t2 = t1 + 0.05;
          _deliver({'type': 'PONG', 't0': msg['t0'], 't1': t1, 't2': t2}, _latency());
      }
    });
  }

  /// Simulates the Start phone detecting the athlete's first movement at local time [localMs].
  void emitStart(double localMs) {
    final remote = localMs + skewMs + localMs * driftPpm / 1e6;
    _deliver({'type': 'START', 't': remote}, _latency());
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _controller.close();
  }
}

class SyncResult {
  const SyncResult({required this.offsetMs, required this.rttMs, required this.samples});

  /// remote − local.
  final double offsetMs;
  final double rttMs;
  final int samples;
}

class ClockSyncEngine {
  ClockSyncEngine(this.transport);

  final SyncTransport transport;
  SyncResult? result;
  StreamSubscription<SyncMessage>? _hostSub;

  static String newPairCode() => (1000 + math.Random.secure().nextInt(9000)).toString();

  /// Finish/Turn phone: find the Start phone by code, then run NTP-style rounds.
  Future<SyncResult> pairAsFinish(String code, {int rounds = 12, Duration timeout = const Duration(seconds: 15)}) async {
    final welcome = transport.incoming.firstWhere((m) => m.type == 'WELCOME' && m.data['code'] == code);
    final hello = Timer.periodic(const Duration(milliseconds: 300), (_) {
      transport.send({'type': 'HELLO', 'code': code});
    });
    transport.send({'type': 'HELLO', 'code': code});
    try {
      await welcome.timeout(timeout);
    } finally {
      hello.cancel();
    }

    final samples = <(double offset, double delay)>[];
    for (var i = 0; i < rounds; i++) {
      final t0 = MonotonicClock.nowMs();
      final pong = transport.incoming
          .firstWhere((m) => m.type == 'PONG' && (m.data['t0'] as num).toDouble() == t0)
          .timeout(const Duration(seconds: 2));
      await transport.send({'type': 'PING', 't0': t0});
      try {
        final m = await pong;
        final t1 = (m.data['t1'] as num).toDouble(), t2 = (m.data['t2'] as num).toDouble();
        final t3 = m.receivedAtMs;
        samples.add((((t1 - t0) + (t2 - t3)) / 2, (t3 - t0) - (t2 - t1)));
      } on TimeoutException {
        continue;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (samples.length < 3) throw TimeoutException('too few sync samples');
    // Lowest-delay samples have the least asymmetric-latency error.
    samples.sort((a, b) => a.$2.compareTo(b.$2));
    final best = samples.take(3).toList();
    result = SyncResult(
      offsetMs: mean(best.map((s) => s.$1)),
      rttMs: mean(best.map((s) => s.$2)),
      samples: samples.length,
    );
    return result!;
  }

  /// Start phone: answer HELLO / PING from the Finish phone.
  void hostAsStart(String code) {
    _hostSub = transport.incoming.listen((m) {
      switch (m.type) {
        case 'HELLO':
          if (m.data['code'] == code) transport.send({'type': 'WELCOME', 'code': code});
        case 'PING':
          final t1 = m.receivedAtMs;
          transport.send({'type': 'PONG', 't0': m.data['t0'], 't1': t1, 't2': MonotonicClock.nowMs()});
      }
    });
  }

  /// Start phone → Finish phone.
  Future<void> sendStart(double localStartMs) => transport.send({'type': 'START', 't': localStartMs});

  Future<void> sendTouch(int leg, bool touched) =>
      transport.send({'type': 'TOUCH', 'leg': leg, 'ok': touched});

  /// START events converted into this phone's clock.
  Stream<double> get remoteStarts => transport.incoming
      .where((m) => m.type == 'START')
      .map((m) => (m.data['t'] as num).toDouble() - (result?.offsetMs ?? 0));

  Future<void> dispose() async {
    await _hostSub?.cancel();
    await transport.close();
  }
}

// ---------------------------------------------------------------------------
// Simulation
// ---------------------------------------------------------------------------

class GateSimulator extends FrameSimulator {
  GateSimulator(this.test, {int seed = 5, this.totalLaps = 4, this.lapLengthM = 200})
      : _noise = SimNoise(seed),
        statureM = SimNoise(seed + 2).uniform(1.35, 1.80) {
    _rig = SideRig(statureM);
    _setup();
  }

  @override
  final SaiTest test;
  final double statureM;
  final int totalLaps;
  final double lapLengthM;
  final SimNoise _noise;
  late final SideRig _rig;
  late final SimCamera cam;
  late double _duration;
  final Map<String, Object?> _truth = {};

  double _startT = 1.5;
  double _vmax = 7.5, _tau = 1.1;
  // Shuttle waypoints: (time, torso X) with zero velocity at each turn.
  final _way = <(double, double)>[];
  final _touchOk = <bool>[];
  // Endurance per-lap speeds.
  final _lapSpeeds = <double>[];

  /// Virtual gate positions (image x) for the simulator's camera.
  List<double> get gateLinesX => switch (test) {
        SaiTest.shuttleRun => [cam.project(0, 0).x, cam.project(10, 0).x],
        SaiTest.sprint30m => [cam.project(30, 0).x],
        _ => [cam.project(0, 0).x],
      };

  @override
  double get width => cam.width;
  @override
  double get height => cam.height;
  @override
  double get fps => test == SaiTest.enduranceRun ? 30 : 60;
  @override
  double get timeScale => test == SaiTest.enduranceRun ? 12 : 1;
  @override
  double get durationMs => _duration * 1000;

  double _sprintX(double t) {
    if (t <= _startT) return -0.3;
    final tau = t - _startT;
    return -0.3 + _vmax * (tau - _tau * (1 - math.exp(-tau / _tau)));
  }

  double _shuttleX(double t) {
    if (t <= _way.first.$1) return _way.first.$2;
    for (var i = 1; i < _way.length; i++) {
      if (t <= _way[i].$1) {
        final (t0, x0) = _way[i - 1];
        final (t1, x1) = _way[i];
        final u = (t - t0) / (t1 - t0);
        // Last leg: accelerate through the finish line (no slowdown before it).
        final e = i == _way.length - 1 ? u * u * (2 - u) : smoothstep(0, 1, u);
        return lerpD(x0, x1, e);
      }
    }
    return _way.last.$2;
  }

  /// Endurance distance s(t): integrated speed with a smooth 1 s acceleration
  /// from the standing start, tabulated every 50 ms.
  final _sTable = <double>[];
  static const _sStep = 0.05;

  void _buildEnduranceTable(double untilS) {
    var s = -0.5;
    _sTable.add(s);
    for (var t = _sStep; t <= untilS; t += _sStep) {
      if (t > _startT) {
        final lap = ((s + 0.5) / lapLengthM).floor().clamp(0, _lapSpeeds.length - 1);
        s += _lapSpeeds[lap] * (1 - math.exp(-(t - _startT) / 1.0)) * _sStep;
      }
      _sTable.add(s);
    }
  }

  double _enduranceS(double t) {
    final i = (t / _sStep).clamp(0.0, _sTable.length - 1.001);
    final k = i.floor();
    return lerpD(_sTable[k], _sTable[k + 1], i - k);
  }

  double xAt(double t) => switch (test) {
        SaiTest.sprint30m => _sprintX(t),
        SaiTest.shuttleRun => _shuttleX(t),
        _ => _wrapLap(_enduranceS(t)),
      };

  double _wrapLap(double s) => ((s + lapLengthM / 2) % lapLengthM) - lapLengthM / 2;

  /// Time at which the torso midpoint crosses world X = [line] (bisection on the rendered rig).
  double _solveCross(double line, double from, double to, double Function(double) torsoX) {
    var a = from, b = to;
    for (var i = 0; i < 60; i++) {
      final m = (a + b) / 2;
      if ((torsoX(m) - line) * (torsoX(b) - line) <= 0) {
        a = m;
      } else {
        b = m;
      }
    }
    return (a + b) / 2;
  }

  double _torsoXWorld(double t) {
    final j = _rig.joints(_pose(t));
    return (j[KP.leftShoulder]!.$1 + j[KP.rightShoulder]!.$1 + j[KP.leftHip]!.$1 + j[KP.rightHip]!.$1) / 4;
  }

  void _setup() {
    switch (test) {
      case SaiTest.sprint30m:
        cam = SimCamera(width: 720, height: 1280, focalPx: 470, position: (15, 1.0, -21));
        _vmax = _noise.uniform(6.3, 8.4);
        _tau = _noise.uniform(0.95, 1.25);
        _startT = _noise.uniform(1.2, 1.8);
        // Finish well after the line.
        _duration = _startT + 7.5;
        final cross = _solveCross(30, _startT + 2, _startT + 7.4, _torsoXWorld);
        _truth['trueTimeS'] = cross - _startT;
      case SaiTest.shuttleRun:
        cam = SimCamera(width: 720, height: 1280, focalPx: 520, position: (5, 1.0, -9.5));
        _startT = _noise.uniform(1.0, 1.6);
        final miss = _noise.chance(0.35) ? _noise.nextInt(3) : -1;
        var t = _startT;
        _way.add((t, -0.35));
        for (var leg = 0; leg < 3; leg++) {
          final ok = leg != miss;
          _touchOk.add(ok);
          final turnX = leg.isEven ? (ok ? 9.72 : 9.25) : (ok ? 0.28 : 0.75);
          t += leg == 0 ? _noise.uniform(2.45, 2.75) : _noise.uniform(2.3, 2.6);
          _way.add((t, turnX));
        }
        t += _noise.uniform(2.6, 3.0);
        _way.add((t, -3.2));
        _duration = t + 0.6;
        final cross = _solveCross(0, _way[3].$1 + 0.5, t, _torsoXWorld);
        _truth['trueTimeS'] = cross - _startT;
        _truth['touches'] = _touchOk;
      case SaiTest.enduranceRun:
        cam = SimCamera(width: 720, height: 1280, focalPx: 520, position: (0, 1.0, -8));
        _startT = 2.0;
        for (var i = 0; i < totalLaps; i++) {
          _lapSpeeds.add(_noise.uniform(3.6, 4.6) - i * 0.08);
        }
        var t = _startT + 1.0;
        for (final v in _lapSpeeds) {
          t += lapLengthM / v;
        }
        _duration = t + 6;
        _buildEnduranceTable(_duration + 1);
        // Torso crossing of the lap line at s = laps·L (accounting for the slow first 3 s).
        final total = totalLaps * lapLengthM;
        double sOf(double tt) {
          final j = _rig.joints(_pose(tt));
          final dx = (j[KP.leftShoulder]!.$1 + j[KP.rightShoulder]!.$1 + j[KP.leftHip]!.$1 + j[KP.rightHip]!.$1) / 4 -
              _wrapLap(_enduranceS(tt));
          return _enduranceS(tt) + dx;
        }

        final cross = _solveCross(total, t - 40, t + 5, sOf);
        _truth['trueTimeS'] = cross - _startT;
        _truth['distanceM'] = total;
      default:
        throw ArgumentError('GateSimulator does not simulate ${test.id}');
    }
    _truth['trueStartS'] = _startT;
  }

  /// When the simulated athlete starts moving (local sim time, ms).
  double get startMs => _startT * 1000;

  RigPose _pose(double t) {
    const dt = 0.02;
    final x = xAt(t);
    final v = (xAt(t + dt) - xAt(t - dt)) / (2 * dt);
    final speed = v.abs();
    var facing = v >= 0 ? 1.0 : -1.0;
    if (speed < 0.05) facing = test == SaiTest.shuttleRun && t > _way.first.$1 + 1 ? facing : 1.0;
    // Distance travelled drives the gait phase.
    final travelled = test == SaiTest.enduranceRun ? _enduranceS(t) : _pathLength(t);
    final cycle = 1.1 + 0.17 * speed;
    final phase = 2 * math.pi * travelled / cycle;
    final amp = speed < 0.05 ? 0.0 : math.min(0.85, 0.2 + 0.08 * speed);
    final flex = amp * 1.2;
    final accel = (xAt(t + dt) - 2 * x + xAt(t - dt)).abs() / (dt * dt);
    var lean = speed < 0.05 ? 0.0 : 0.12 + math.min(0.35, accel * 0.04);
    // Finish dip (sprint): torso pitches forward; arms swing back.
    var dip = 0.0;
    if (test == SaiTest.sprint30m) dip = smoothstep(28.5, 29.8, x) * (1 - smoothstep(30.5, 31.5, x));
    lean += dip * 0.5;
    final hipBob = speed < 0.05 ? 0.0 : 0.025 * (1 - math.cos(2 * phase)) - 0.04;

    var thighL = amp * math.sin(phase), thighR = amp * math.sin(phase + math.pi);
    var shinL = thighL - flex * (0.5 + 0.5 * math.sin(phase + 1.2));
    final shinR = thighR - flex * (0.5 + 0.5 * math.sin(phase + math.pi + 1.2));

    // Shuttle: plant the leading foot over the line at each turn.
    if (test == SaiTest.shuttleRun) {
      for (var i = 1; i <= 3; i++) {
        final tt = _way[i].$1;
        final w = smoothstep(tt - 0.35, tt - 0.05, t) * (1 - smoothstep(tt + 0.05, tt + 0.3, t));
        thighL = lerpD(thighL, 0.95, w);
        shinL = lerpD(shinL, 0.35, w);
      }
    }
    return RigPose(
      hipX: x,
      hipY: _rig.standingHipY + hipBob,
      facing: facing,
      torso: math.pi - lean,
      thighL: thighL,
      shinL: shinL,
      thighR: thighR,
      shinR: shinR,
      upperArmL: -amp * 0.9 * math.sin(phase) - dip * 1.2,
      forearmL: -amp * 0.9 * math.sin(phase) + 1.3 - dip,
      upperArmR: -amp * 0.9 * math.sin(phase + math.pi) - dip * 1.2,
      forearmR: -amp * 0.9 * math.sin(phase + math.pi) + 1.3 - dip,
    );
  }

  double _pathLength(double t) {
    if (test == SaiTest.sprint30m) return _sprintX(t) + 0.3;
    var len = 0.0;
    var prev = xAt(_way.first.$1);
    for (var tt = _way.first.$1; tt < t; tt += 0.05) {
      final x = xAt(tt);
      len += (x - prev).abs();
      prev = x;
    }
    return len;
  }

  @override
  PoseFrame frameAt(double tMs, int index) {
    final t = tMs / 1000;
    if (test == SaiTest.enduranceRun) {
      final x = _wrapLap(_enduranceS(t));
      if (x.abs() > 6.5) {
        return renderRig(rig: _rig, pose: RigPose(hipX: 0, hipY: 1), cam: cam, noise: _noise, tMs: tMs, index: index, visible: false);
      }
    }
    return renderRig(
      rig: _rig,
      pose: _pose(t),
      cam: cam,
      noise: _noise,
      tMs: tMs,
      index: index,
      pixelSigma: test == SaiTest.sprint30m ? 0.6 : 1.0,
    );
  }

  @override
  List<HudPrimitive> scenery(double tMs) => [
        HudLine(cam.project(-40, 0), cam.project(40, 0), tone: HudTone.neutral, width: 3),
        if (test == SaiTest.sprint30m) HudLine(cam.project(0, 0), cam.project(0, 0.3), tone: HudTone.neutral, width: 3, label: 'START'),
      ];

  @override
  Map<String, Object?> get groundTruth => _truth;
}
