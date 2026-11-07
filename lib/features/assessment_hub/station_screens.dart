import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/database/repository.dart';
import '../../core/domain/sai_test.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';
import 'roster_screen.dart';
import 'test_visuals.dart';

/// Station-wise mode: pick the test station this assessor is running.
class StationPickerScreen extends ConsumerWidget {
  const StationPickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    return AppScaffold(
      title: l.t('station_pick'),
      body: GridView.builder(
        padding: const EdgeInsets.all(AppSpace.md),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisExtent: 148,
          crossAxisSpacing: AppSpace.sm,
          mainAxisSpacing: AppSpace.sm,
        ),
        itemCount: SaiTest.values.length,
        itemBuilder: (_, i) {
          final t = SaiTest.values[i];
          return Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(AppSpace.radius),
              onTap: () => context.push(Routes.station(t)),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(testIcon(t), color: AppColors.primary, size: 30),
                    const Spacer(),
                    Flexible(
                      child: Text(
                        l.testName(t),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(t.toleranceLabel, style: AppText.metricS),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Station queue: every athlete, pending first, for one test.
class StationQueueScreen extends ConsumerWidget {
  const StationQueueScreen({super.key, required this.test});
  final SaiTest test;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final athletes = ref.watch(athletesProvider);
    final results = ref.watch(stationResultsProvider(test)).valueOrNull ?? const {};
    final consented = ref.watch(consentedIdsProvider).valueOrNull ?? const <String>{};
    final counts = ref.watch(completedCountsProvider).valueOrNull ?? const {};

    return AppScaffold(
      title: l.t('station_title', {'test': l.testName(test)}),
      bottom: PrimaryButton(
        label: l.t('roster_add'),
        icon: Icons.person_add_alt_1_rounded,
        onPressed: () => context.push('${Routes.register}?station=${test.id}'),
      ),
      body: AsyncValueView(
        value: athletes,
        data: (list) {
          if (list.isEmpty) return EmptyState(icon: Icons.group_add_outlined, message: l.t('roster_empty'));
          final pending = list.where((a) => !results.containsKey(a.id)).toList();
          final completed = list.where((a) => results.containsKey(a.id)).toList();
          Widget tile(a) {
            final best = bestByTest(results[a.id] ?? const [])[test];
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: AthleteTile(
                athlete: a,
                done: counts[a.id] ?? 0,
                consented: consented.contains(a.id),
                trailing: best == null
                    ? const Icon(Icons.play_circle_fill_rounded, color: AppColors.primary, size: 32)
                    : Text('${test.format(best.finalScore)} ${l.unit(test)}', style: AppText.metricM),
                onTap: () async {
                  if (!await confirmStorageBeforeTest(context, ref)) return;
                  if (context.mounted) context.push(Routes.workbench(a.id, test));
                },
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.lg),
            children: [
              Text(l.t(test.setupKey), style: const TextStyle(color: AppColors.textMuted)),
              SectionHeader('${l.t('station_pending')} (${pending.length})'),
              ...pending.map(tile),
              if (completed.isNotEmpty) SectionHeader('${l.t('station_completed')} (${completed.length})'),
              ...completed.map(tile),
            ],
          );
        },
      ),
    );
  }
}
