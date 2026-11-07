import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/repository.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';

/// 30-day soft-delete recycle bin (expired items are purged at app start).
class RecycleBinScreen extends ConsumerWidget {
  const RecycleBinScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final items = ref.watch(recycleBinProvider);
    final now = DateTime.now();
    String date(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

    return AppScaffold(
      title: l.t('reports_recycle_bin'),
      body: AsyncValueView(
        value: items,
        data: (list) => list.isEmpty
            ? EmptyState(icon: Icons.delete_outline_rounded, message: l.t('reports_bin_empty'))
            : ListView.separated(
                padding: const EdgeInsets.all(AppSpace.md),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: AppSpace.sm),
                itemBuilder: (_, i) {
                  final it = list[i];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(it.kind == 'athlete' ? Icons.person_outline : Icons.assignment_outlined,
                                  color: AppColors.textMuted),
                              const SizedBox(width: AppSpace.sm),
                              Expanded(
                                child: Text(it.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleMedium),
                              ),
                            ],
                          ),
                          if (it.subtitle.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(it.subtitle, style: AppText.metricS),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            l.t('reports_bin_expires', {'date': date(it.deletedAt), 'days': it.daysLeft(now).clamp(0, 30)}),
                            style: const TextStyle(fontSize: 12, color: AppColors.warning),
                          ),
                          const SizedBox(height: AppSpace.sm),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => ref.read(repositoryProvider).restore(it),
                                  icon: const Icon(Icons.restore_rounded),
                                  label: Text(l.t('restore')),
                                ),
                              ),
                              const SizedBox(width: AppSpace.sm),
                              Expanded(
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(backgroundColor: AppColors.foul),
                                  onPressed: () => ref.read(repositoryProvider).deleteForever(it),
                                  icon: const Icon(Icons.delete_forever_outlined),
                                  label: Text(l.t('reports_delete_forever'), maxLines: 1, overflow: TextOverflow.ellipsis),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
