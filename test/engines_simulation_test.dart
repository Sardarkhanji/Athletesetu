import 'dart:typed_data';

// Headless accuracy checks: every simulator is driven through its real engine
// and the measured value is compared with the simulator's ground truth.

import 'package:athlete_setu/core/domain/sai_test.dart';
import 'package:athlete_setu/engines/assisted_ocr_engine.dart';
import 'package:athlete_setu/engines/calibration_engine.dart';
import 'package:athlete_setu/engines/engine_registry.dart';
import 'package:athlete_setu/engines/pose_fsm_engine.dart';
import 'package:athlete_setu/engines/pose_types.dart';
import 'package:athlete_setu/engines/timing_gate_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs a full simulated attempt; returns (outcome, truth).
(AttemptOutcome, Map<String, Object?>, MeasurementSession) runSim(SaiTest test, int seed) {
  final sim = EngineRegistry.createSimulator(test, seed: seed);
  final cal = EngineRegistry.simulatedCalibration(sim, level: const LevelReading(0.3, 0.2));
  final session = EngineRegistry.createSession(
    test,
    cal,
    SessionConfig(athleteHeightCm: EngineRegistry.simulatedStatureCm(sim)),
  );
  final dt = 1000 / sim.fps;
  var i = 0;
  for (var t = 0.0; t <= sim.durationMs && !session.isComplete; t += dt) {
    session.process(sim.frameAt(t, i++));
  }
  return (session.finalize(), sim.groundTruth, session);
}

void main() {
  const seeds = [1, 2, 3, 4, 5, 6];

  test('homography round-trips', () {
    final src = [const Vec2(10, 10), const Vec2(200, 20), const Vec2(210, 190), const Vec2(5, 180)];
    final dst = [const Vec2(0, 20), const Vec2(20, 20), const Vec2(20, 0), const Vec2(0, 0)];
    final h = Homography.fromPoints(src, dst)!;
    for (var k = 0; k < 4; k++) {
      expect(h.map(src[k]).distanceTo(dst[k]), lessThan(1e-6));
    }
    expect(h.inverse().map(dst[2]).distanceTo(src[2]), lessThan(1e-6));
  });

  test('height ±1 cm', () {
    for (final s in seeds) {
      final (o, truth, _) = runSim(SaiTest.height, s);
      final err = (o.value! - (truth['trueHeightCm'] as double)).abs();
      // ignore: avoid_print
      print('height seed=$s value=${o.value!.toStringAsFixed(1)} truth=${(truth['trueHeightCm'] as double).toStringAsFixed(1)} err=${err.toStringAsFixed(2)} conf=${o.confidence.round()}');
      expect(err, lessThan(1.0));
    }
  });

  test('vertical jump ±2 cm (reach-equivalent)', () {
    for (final s in seeds) {
      final (o, truth, _) = runSim(SaiTest.verticalJump, s);
      expect(o.value, isNotNull, reason: 'seed $s fouls=${o.fouls}');
      final t = truth['trueReachDeltaCm'] as double;
      final err = (o.value! - t).abs();
      // ignore: avoid_print
      print('vj seed=$s value=${o.value!.toStringAsFixed(1)} truth=${t.toStringAsFixed(1)} err=${err.toStringAsFixed(2)} '
          'spatial=${o.metadata['spatialDeltaCm']} flightEq=${o.metadata['flightReachEquivalentCm']} conf=${o.confidence.round()}');
      expect(err, lessThan(2.0));
    }
  });

  test('broad jump ±2 cm', () {
    for (final s in seeds) {
      final (o, truth, _) = runSim(SaiTest.broadJump, s);
      expect(o.value, isNotNull, reason: 'seed $s fouls=${o.fouls}');
      final t = truth['trueDistanceCm'] as double;
      final err = (o.value! - t).abs();
      // ignore: avoid_print
      print('bj seed=$s value=${o.value!.toStringAsFixed(1)} truth=${t.toStringAsFixed(1)} err=${err.toStringAsFixed(2)} conf=${o.confidence.round()}');
      expect(err, lessThan(2.0));
    }
  });

  test('sit & reach ±2 cm, best of 3 with 1.5 s hold', () {
    for (final s in seeds) {
      final (o, truth, _) = runSim(SaiTest.sitAndReach, s);
      final t = truth['trueBestReachCm'] as double?;
      // ignore: avoid_print
      print('sr seed=$s value=${o.value?.toStringAsFixed(1)} truth=${t?.toStringAsFixed(1)} attempts=${truth['attemptReachCm']} fouls=${o.fouls} conf=${o.confidence.round()}');
      if (t == null) {
        expect(o.value, isNull);
      } else {
        expect((o.value! - t).abs(), lessThan(2.0));
      }
    }
  });

  test('sit-ups FSM ≥95% rep accuracy with foul rejection', () {
    var expected = 0, matched = 0;
    for (final s in seeds) {
      final (o, truth, _) = runSim(SaiTest.sitUps, s);
      final t = truth['expectedValidReps'] as int;
      // ignore: avoid_print
      print('situps seed=$s valid=${o.value} truth=$t attempted=${o.metadata['attemptedReps']} fouls=${o.metadata['foulCounts']} conf=${o.confidence.round()}');
      expected += t;
      matched += t - (o.value!.round() - t).abs();
    }
    expect(matched / expected, greaterThanOrEqualTo(0.95));
  });

  test('sit-up window by age (30 s under 12, 45 s for 12+)', () {
    expect(SaiTest.sitUps.durationSecForAge(11), 30);
    expect(SaiTest.sitUps.durationSecForAge(12), 45);
    expect(SaiTest.sitUps.durationSecForAge(17), 45);
    expect(SaiTest.sitUps.durationSecForAge(null), 45);
    expect(SaiTest.height.durationSecForAge(10), isNull);
  });

  test('level reading: landscape (top to the left) is level when gravity is along +x', () {
    expect(LevelReading.fromAccelerometer(9.8, 0, 0, landscape: true).rollDeg.abs(), lessThan(0.01));
    expect(LevelReading.fromAccelerometer(0, 9.8, 0).rollDeg.abs(), lessThan(0.01));
    // A 5° tilt reads as 5° in either orientation.
    final r = LevelReading.fromAccelerometer(9.8 * 0.99619, -9.8 * 0.08716, 0, landscape: true);
    expect(r.rollDeg.abs(), closeTo(5, 0.05));
  });

  test('marker detector measures a square edge-to-edge (no 1-pixel shrink)', () {
    const w = 400, h = 400, x0 = 150, side = 100;
    final gray = Uint8List(w * h)..fillRange(0, w * h, 220);
    for (var y = x0; y < x0 + side; y++) {
      for (var x = x0; x < x0 + side; x++) {
        gray[y * w + x] = 20;
      }
    }
    final quads = detectSquareMarkers(gray, w, h, maxMarkers: 1);
    expect(quads, hasLength(1));
    final q = quads.first;
    final mean = [for (var i = 0; i < 4; i++) q[i].distanceTo(q[(i + 1) % 4])].reduce((a, b) => a + b) / 4;
    expect(mean, closeTo(side, 0.6));
  });

  test('sit-ups wait for GO: nothing counts before startAt', () {
    final sim = EngineRegistry.createSimulator(SaiTest.sitUps, seed: 3);
    final cal = EngineRegistry.simulatedCalibration(sim);
    final session = EngineRegistry.createSession(
      SaiTest.sitUps,
      cal,
      const SessionConfig(waitForGo: true),
    ) as SitUpSession;
    final dt = 1000 / sim.fps;
    var i = 0;
    for (var t = 0.0; t <= sim.durationMs; t += dt) {
      session.process(sim.frameAt(t, i++));
    }
    expect(session.isComplete, isFalse);
    expect(session.finalize().value, isNull);
  });

  test('sit-ups 45 s window counts more reps than 30 s', () {
    int countFor(int sec) {
      final sim = EngineRegistry.createSimulator(SaiTest.sitUps, seed: 2, durationSec: sec);
      final cal = EngineRegistry.simulatedCalibration(sim);
      final session = EngineRegistry.createSession(SaiTest.sitUps, cal, SessionConfig(durationSec: sec));
      final dt = 1000 / sim.fps;
      var i = 0;
      for (var t = 0.0; t <= sim.durationMs && !session.isComplete; t += dt) {
        session.process(sim.frameAt(t, i++));
      }
      final o = session.finalize();
      expect(o.metadata['durationSec'], sec.toDouble());
      final truth = sim.groundTruth['expectedValidReps'] as int;
      expect((o.value!.round() - truth).abs(), lessThanOrEqualTo(1));
      return o.value!.round();
    }

    expect(countFor(45), greaterThan(countFor(30)));
  });

  test('sprint / shuttle / endurance timing', () {
    for (final test in [SaiTest.sprint30m, SaiTest.shuttleRun, SaiTest.enduranceRun]) {
      for (final s in seeds.take(4)) {
        final (o, truth, _) = runSim(test, s);
        expect(o.value, isNotNull, reason: '${test.id} seed $s');
        final t = truth['trueTimeS'] as double;
        final err = (o.value! - t).abs();
        // ignore: avoid_print
        print('${test.id} seed=$s value=${o.value!.toStringAsFixed(3)} truth=${t.toStringAsFixed(3)} err=${(err * 1000).round()}ms fouls=${o.fouls} touches=${truth['touches']} conf=${o.confidence.round()}');
        expect(err, lessThan(test == SaiTest.enduranceRun ? 0.15 : 0.05));
        if (test == SaiTest.shuttleRun) {
          final missed = (truth['touches'] as List).where((v) => v == false).length;
          expect(o.metadata['missedTouches'], missed);
        }
      }
    }
  });

  test('medicine ball ±5 cm proposal', () {
    for (final s in seeds) {
      final (o, truth, _) = runSim(SaiTest.medicineBall, s);
      expect(o.value, isNotNull, reason: 'seed $s');
      final t = truth['trueDistanceCm'] as double;
      final err = (o.value! - t).abs();
      // ignore: avoid_print
      print('mb seed=$s value=${o.value!.toStringAsFixed(1)} truth=${t.toStringAsFixed(1)} err=${err.toStringAsFixed(2)} conf=${o.confidence.round()}');
      expect(err, lessThan(5.0));
    }
  });

  test('weight seven-segment OCR ±0.1 kg', () {
    final engine = const WeightOcrEngine();
    for (final s in seeds) {
      final kg = 18 + s * 9.37;
      final (img, roi) = ScaleDisplaySimulator(seed: s).render(kg);
      final o = engine.read(img, roi: roi, heightCm: 150);
      // ignore: avoid_print
      print('weight seed=$s truth=${kg.toStringAsFixed(1)} read=${o.value} text=${o.metadata['ocrText']} bmi=${o.metadata['bmi']} conf=${o.confidence.round()}');
      expect(o.value, closeTo(double.parse(kg.toStringAsFixed(1)), 0.051));
    }
  });

  test('clock sync estimates the simulated skew', () async {
    final peer = SimulatedPeerTransport(seed: 7, skewMs: 3742.5);
    final sync = ClockSyncEngine(peer);
    final r = await sync.pairAsFinish('1234', rounds: 10);
    // ignore: avoid_print
    print('sync offset=${r.offsetMs.toStringAsFixed(2)} rtt=${r.rttMs.toStringAsFixed(2)} samples=${r.samples}');
    expect((r.offsetMs - 3742.5).abs(), lessThan(8));
    await sync.dispose();
  });
}
