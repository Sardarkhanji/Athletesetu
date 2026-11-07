import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/database/repository.dart';
import '../../core/domain/entities.dart';
import '../../core/domain/sai_test.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';
import '../../engines/assisted_ocr_engine.dart' show bmi;
import '../reports_sync/pdf_report_service.dart';
import 'test_visuals.dart';

/// The 10 SAI battery tests for one athlete, with best score and attempts.
class AthleteHubScreen extends ConsumerWidget {
  const AthleteHubScreen({super.key, required this.athleteId});
  final String athleteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final athlete = ref.watch(athleteProvider(athleteId));
    final results = ref.watch(resultsProvider(athleteId));
    final consent = ref.watch(consentProvider(athleteId)).valueOrNull;

    return AppScaffold(
      title: athlete.valueOrNull?.name ?? l.t('hub_title'),
      actions: [
        IconButton(
          tooltip: l.t('hub_report'),
          icon: const Icon(Icons.picture_as_pdf_outlined),
          onPressed: athlete.valueOrNull == null
              ? null
              : () => exportAthletePdf(context, ref, athlete.valueOrNull!),
        ),
      ],
      body: AsyncValueView(
        value: athlete,
        data: (a) {
          if (a == null) return const SizedBox.shrink();
          final list = results.valueOrNull ?? const <TestResult>[];
          final best = bestByTest(list);
          final attempts = <SaiTest, int>{};
          for (final r in list) {
            attempts[r.test] = (attempts[r.test] ?? 0) + 1;
          }
          final weight = best[SaiTest.weight]?.finalScore;
          final height = best[SaiTest.height]?.finalScore ?? a.heightCm;
          return ListView(
            padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.xl),
            children: [
              _Header(athlete: a, consentOk: consent?.isValid ?? false, bmiValue: weight != null && height != null ? bmi(weight, height) : null),
              const SizedBox(height: AppSpace.md),
              for (final t in SaiTest.values) ...[
                _TestRow(
                  test: t,
                  best: best[t],
                  attempts: attempts[t] ?? 0,
                  onTap: () async {
                    if (!await confirmStorageBeforeTest(context, ref)) return;
                    if (context.mounted) context.push(Routes.workbench(a.id, t));
                  },
                ),
                const SizedBox(height: AppSpace.sm),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.athlete, required this.consentOk, this.bmiValue});
  final Athlete athlete;
  final bool consentOk;
  final double? bmiValue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                '${athlete.age} ${l.t('years')}',
                athlete.gender,
                if (athlete.school.isNotEmpty) athlete.school,
                if (athlete.district.isNotEmpty) athlete.district,
              ].join(' · '),
              style: const TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                StatusPill(
                  label: l.t(consentOk ? 'consent_ok' : 'consent_missing'),
                  color: consentOk ? AppColors.pass : AppColors.warning,
                  icon: consentOk ? Icons.verified_user_outlined : Icons.lock_outline_rounded,
                ),
                if (athlete.isMinor)
                  StatusPill(label: l.t('reg_minor_badge'), color: AppColors.warning, icon: Icons.family_restroom_rounded),
                if (bmiValue != null)
                  StatusPill(label: l.t('hub_bmi', {'value': bmiValue!.toStringAsFixed(1)}), color: AppColors.primary),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TestRow extends ConsumerWidget {
  const _TestRow({required this.test, required this.best, required this.attempts, required this.onTap});
  final SaiTest test;
  final TestResult? best;
  final int attempts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final done = best != null;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpace.radius),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (done ? AppColors.pass : AppColors.primary).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(testIcon(test), color: done ? AppColors.pass : AppColors.primary),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.testName(test), style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        done
                            ? l.t('hub_attempts', {'n': attempts, 'max': test.attempts})
                            : l.t('hub_not_started'),
                        style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                if (done)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(text: test.format(best!.finalScore), style: AppText.metricM),
                          TextSpan(text: ' ${l.unit(test)}', style: AppText.metricS),
                        ]),
                      ),
                      const SizedBox(height: 4),
                      if (best!.isOverride)
                        StatusPill(label: l.t('pdf_method_manual'), color: AppColors.warning)
                      else
                        ConfidenceBadge(confidence: best!.confidence, compact: true),
                    ],
                  )
                else
                  const Icon(Icons.play_circle_fill_rounded, color: AppColors.primary, size: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
