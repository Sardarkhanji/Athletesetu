/// Single entry point mapping each SAI test to its engine, simulator and
/// (simulated) calibration. The camera workbench depends only on this file.
library;

import 'dart:math' as math;

import '../core/domain/sai_test.dart';
import 'assisted_ocr_engine.dart';
import 'calibration_engine.dart';
import 'jump_reach_engine.dart';
import 'pose_fsm_engine.dart';
import 'pose_types.dart';
import 'timing_gate_engine.dart';

class SessionConfig {
  const SessionConfig({
    this.athleteHeightCm,
    this.enduranceLaps = 4,
    this.useRemoteStart = false,
  });
  final double? athleteHeightCm;
  final int enduranceLaps;
  final bool useRemoteStart;
}

abstract final class EngineRegistry {
  static const calibration = CalibrationEngine();

  /// Creates the measurement state machine for a pose/video test.
  static MeasurementSession createSession(SaiTest test, CalibrationResult cal, SessionConfig cfg) =>
      switch (test.engine) {
        EngineKind.poseFsm => SitUpSession(durationSec: test.durationSec),
        EngineKind.jumpReach => createJumpReachSession(test, cal, athleteHeightCm: cfg.athleteHeightCm),
        EngineKind.timingGate => TimingGateSession(
            test: test,
            linesX: cal.gateLinesX,
            imageWidth: cal.imageWidth,
            totalLaps: cfg.enduranceLaps,
            useRemoteStart: cfg.useRemoteStart,
          ),
        EngineKind.assistedOcr when test == SaiTest.medicineBall => MedicineBallSession(cal),
        _ => throw ArgumentError('${test.id} has no video session (weight uses a still photo)'),
      };

  /// A fresh simulator with a random seed (each attempt differs).
  static FrameSimulator createSimulator(SaiTest test, {int? seed, int enduranceLaps = 4}) {
    final s = seed ?? math.Random().nextInt(1 << 30);
    return switch (test) {
      SaiTest.sitUps => SitUpSimulator(seed: s),
      SaiTest.height || SaiTest.verticalJump || SaiTest.broadJump || SaiTest.sitAndReach =>
        JumpReachSimulator(test, seed: s),
      SaiTest.sprint30m || SaiTest.shuttleRun || SaiTest.enduranceRun =>
        GateSimulator(test, seed: s, totalLaps: enduranceLaps),
      SaiTest.medicineBall => MedicineBallSimulator(seed: s),
      SaiTest.weight => throw ArgumentError('weight is simulated by ScaleDisplaySimulator'),
    };
  }

  /// Runs the real calibration maths on markers projected by the simulator's camera.
  static CalibrationResult simulatedCalibration(FrameSimulator sim, {LevelReading? level}) {
    final calSim = CalibrationSimulator();
    final quality = calSim.quality(sim);
    final kind = sim.test.calibration;
    switch (kind) {
      case CalibrationKind.wallMarker:
      case CalibrationKind.boxScale:
        final js = sim as JumpReachSimulator;
        final place = js.markerPlacement;
        return calibration.fromMarkers(
          kind: kind,
          markers: calSim.markers(js.cam, kind, wallX: place.wallX, wallBaseY: place.wallBaseY),
          imageWidth: sim.width,
          imageHeight: sim.height,
          level: level,
          quality: quality,
          simulated: true,
        );
      case CalibrationKind.floorMarkers:
        final cam = sim is JumpReachSimulator ? sim.cam : (sim as MedicineBallSimulator).cam;
        return calibration.fromMarkers(
          kind: kind,
          markers: calSim.markers(cam, kind),
          imageWidth: sim.width,
          imageHeight: sim.height,
          level: level,
          quality: quality,
          simulated: true,
        );
      case CalibrationKind.finishLine:
        return calibration.forGates(
          linesX: (sim as GateSimulator).gateLinesX,
          imageWidth: sim.width,
          imageHeight: sim.height,
          level: level,
          quality: quality,
          simulated: true,
        );
      case CalibrationKind.none:
        return calibration.none(imageWidth: sim.width, imageHeight: sim.height, simulated: true);
    }
  }

  /// Default gate line positions for a live camera frame (assessor can drag them).
  static List<double> defaultGateLines(SaiTest test, double imageWidth) =>
      test == SaiTest.shuttleRun ? [imageWidth * 0.12, imageWidth * 0.88] : [imageWidth * 0.5];

  /// Simulated athlete stature, if the simulator knows it (used for heel offsets).
  static double? simulatedStatureCm(FrameSimulator sim) => switch (sim) {
        JumpReachSimulator s => s.statureM * 100,
        GateSimulator s => s.statureM * 100,
        MedicineBallSimulator s => s.statureM * 100,
        SitUpSimulator s => s.statureM * 100,
        _ => null,
      };
}
