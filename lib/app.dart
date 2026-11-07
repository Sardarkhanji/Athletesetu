import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/database/repository.dart';
import 'core/domain/sai_test.dart';
import 'core/theme/app_theme.dart';
import 'features/assessment_hub/athlete_hub_screen.dart';
import 'features/assessment_hub/roster_screen.dart';
import 'features/assessment_hub/station_screens.dart';
import 'features/camera_workbench/workbench_screen.dart';
import 'features/mode_selection/mode_selection_screen.dart';
import 'features/registration/consent_gate_screen.dart';
import 'features/registration/registration_screen.dart';
import 'features/reports_sync/recycle_bin_screen.dart';
import 'features/reports_sync/reports_screen.dart';

/// Flat route table.
abstract final class Routes {
  static const mode = '/';
  static const roster = '/roster';
  static const register = '/register';
  static const stations = '/stations';
  static const reports = '/reports';
  static const recycleBin = '/reports/bin';

  static String athlete(String id) => '/athlete/$id';
  static String consent(String id) => '/athlete/$id/consent';
  static String station(SaiTest t) => '/station/${t.id}';
  static String workbench(String athleteId, SaiTest t) => '/workbench/$athleteId/${t.id}';
}

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: Routes.mode,
    routes: [
      GoRoute(path: Routes.mode, builder: (_, _) => const ModeSelectionScreen()),
      GoRoute(path: Routes.roster, builder: (_, _) => const RosterScreen()),
      GoRoute(
        path: Routes.register,
        builder: (_, s) => RegistrationScreen(returnToStation: s.uri.queryParameters['station']),
      ),
      GoRoute(path: Routes.stations, builder: (_, _) => const StationPickerScreen()),
      GoRoute(
        path: '/station/:testId',
        builder: (_, s) => StationQueueScreen(test: SaiTest.fromId(s.pathParameters['testId']!)),
      ),
      GoRoute(
        path: '/athlete/:id',
        builder: (_, s) => AthleteHubScreen(athleteId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/athlete/:id/consent',
        builder: (_, s) => ConsentGateScreen(
          athleteId: s.pathParameters['id']!,
          nextTestId: s.uri.queryParameters['next'],
        ),
      ),
      GoRoute(
        path: '/workbench/:athleteId/:testId',
        // DPDP gate: no camera without a valid consent record.
        redirect: (context, state) async {
          final id = state.pathParameters['athleteId']!;
          final ok = await ref.read(repositoryProvider).hasValidConsent(id);
          return ok ? null : '${Routes.consent(id)}?next=${state.pathParameters['testId']}';
        },
        builder: (_, s) => WorkbenchScreen(
          athleteId: s.pathParameters['athleteId']!,
          test: SaiTest.fromId(s.pathParameters['testId']!),
        ),
      ),
      GoRoute(path: Routes.reports, builder: (_, _) => const ReportsScreen()),
      GoRoute(path: Routes.recycleBin, builder: (_, _) => const RecycleBinScreen()),
    ],
  );
});

class AthleteSetuApp extends ConsumerWidget {
  const AthleteSetuApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'AthleteSetu',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        // Cap text scaling so sunlight-readable layouts never overflow.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: mq.textScaler.clamp(maxScaleFactor: 1.3)),
          child: child!,
        );
      },
    );
  }
}
