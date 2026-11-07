import 'package:flutter/material.dart';

import '../../core/domain/sai_test.dart';

IconData testIcon(SaiTest t) => switch (t) {
      SaiTest.height => Icons.height_rounded,
      SaiTest.weight => Icons.monitor_weight_outlined,
      SaiTest.sitAndReach => Icons.accessibility_new_rounded,
      SaiTest.verticalJump => Icons.upload_rounded,
      SaiTest.broadJump => Icons.trending_flat_rounded,
      SaiTest.medicineBall => Icons.sports_volleyball_outlined,
      SaiTest.sprint30m => Icons.directions_run_rounded,
      SaiTest.shuttleRun => Icons.swap_horiz_rounded,
      SaiTest.sitUps => Icons.fitness_center_rounded,
      SaiTest.enduranceRun => Icons.timer_outlined,
    };
