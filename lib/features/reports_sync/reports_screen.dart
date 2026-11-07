import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/database/repository.dart';
import '../../core/localization/l10n.dart';
import '../../core/permissions/permission_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';
import 'pdf_report_service.dart';

/// Bilingual PDF export, decoupled video storage, training labels, recycle bin.
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final athletes = ref.watch(athletesProvider);
    final stats = ref.watch(videoStatsProvider).valueOrNull;
    final labels = ref.watch(trainingLabelCountProvider).valueOrNull ?? 0;
    final counts = ref.watch(completedCountsProvider).valueOrNull ?? const {};
    final bin = ref.watch(recycleBinProvider).valueOrNull ?? const [];

    return AppScaffold(
      title: l.t('reports_title'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.xl),
        children: [
          SectionHeader(l.t('reports_videos')),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l.t('reports_videos_summary', {
                      'count': stats?.count ?? 0,
                      'size': formatBytes(stats?.bytes ?? 0),
                    }),
                    style: AppText.metricM,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l.t('reports_synced_videos', {
                      'count': stats?.syncedCount ?? 0,
                      'size': formatBytes(stats?.syncedBytes ?? 0),
                    }),
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: AppSpace.md),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.text),
                    onPressed: (stats?.syncedCount ?? 0) == 0 ? null : () => _clearSynced(context, ref, stats!.syncedCount),
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: Text(l.t('reports_clear_synced')),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(l.t('reports_mark_synced'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                ],
              ),
            ),
          ),
          SectionHeader(l.t('reports_recycle_bin')),
          Card(
            child: ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.restore_from_trash_outlined),
              title: Text(l.t('reports_recycle_bin')),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${bin.length}', style: AppText.metricM),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              onTap: () => context.push(Routes.recycleBin),
            ),
          ),
          SectionHeader(l.t('reports_training_labels')),
          Card(
            child: ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.model_training_outlined),
              title: Text(l.t('reports_training_count', {'count': labels})),
            ),
          ),
          SectionHeader(l.t('reports_athletes')),
          AsyncValueView(
            value: athletes,
            data: (list) => list.isEmpty
                ? EmptyState(icon: Icons.description_outlined, message: l.t('reports_no_results'))
                : Column(
                    children: [
                      for (final a in list)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpace.sm),
                          child: Card(
                            child: ListTile(
                              minTileHeight: 64,
                              title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(l.t('roster_progress', {'done': counts[a.id] ?? 0})),
                              trailing: IconButton.filledTonal(
                                tooltip: l.t('reports_export_pdf'),
                                icon: const Icon(Icons.picture_as_pdf_outlined),
                                onPressed: () => exportAthletePdf(context, ref, a),
                              ),
                              onTap: () => context.push(Routes.athlete(a.id)),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _clearSynced(BuildContext context, WidgetRef ref, int count) async {
    final l = ref.read(l10nProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('reports_clear_synced')),
        content: Text(l.t('reports_clear_confirm', {'count': count})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    final freed = await ref.read(repositoryProvider).clearSyncedVideos();
    ref.invalidate(freeStorageProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.t('reports_cleared', {'size': formatBytes(freed)}))),
      );
    }
  }
}
