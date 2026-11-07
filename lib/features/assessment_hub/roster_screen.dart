import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/database/repository.dart';
import '../../core/domain/entities.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';

/// Athlete roster queue (individual and athlete-wise coach modes).
class RosterScreen extends ConsumerStatefulWidget {
  const RosterScreen({super.key});

  @override
  ConsumerState<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends ConsumerState<RosterScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(l10nProvider);
    final athletes = ref.watch(athletesProvider);
    final counts = ref.watch(completedCountsProvider).valueOrNull ?? const {};
    final consented = ref.watch(consentedIdsProvider).valueOrNull ?? const <String>{};

    return AppScaffold(
      title: l.t('roster_title'),
      actions: [
        IconButton(
          tooltip: l.t('reports_title'),
          icon: const Icon(Icons.picture_as_pdf_outlined),
          onPressed: () => context.push(Routes.reports),
        ),
      ],
      bottom: PrimaryButton(
        label: l.t('roster_add'),
        icon: Icons.person_add_alt_1_rounded,
        onPressed: () => context.push(Routes.register),
      ),
      body: AsyncValueView(
        value: athletes,
        data: (list) {
          if (list.isEmpty) return EmptyState(icon: Icons.group_add_outlined, message: l.t('roster_empty'));
          final q = _query.toLowerCase();
          final filtered = q.isEmpty
              ? list
              : list.where((a) => a.name.toLowerCase().contains(q) || a.school.toLowerCase().contains(q)).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.sm, AppSpace.md, AppSpace.sm),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: l.t('roster_search'),
                    prefixIcon: const Icon(Icons.search_rounded),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.lg),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpace.sm),
                  itemBuilder: (_, i) => AthleteTile(
                    athlete: filtered[i],
                    done: counts[filtered[i].id] ?? 0,
                    consented: consented.contains(filtered[i].id),
                    onTap: () => context.push(Routes.athlete(filtered[i].id)),
                    onDelete: () => _confirmDelete(filtered[i]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(Athlete a) async {
    final l = ref.read(l10nProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.t('delete_athlete')),
        content: Text(l.t('delete_athlete_confirm', {'name': a.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.foul),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.t('delete')),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(repositoryProvider).softDeleteAthlete(a.id);
  }
}

class AthleteTile extends ConsumerWidget {
  const AthleteTile({
    super.key,
    required this.athlete,
    required this.done,
    required this.consented,
    required this.onTap,
    this.onDelete,
    this.trailing,
  });

  final Athlete athlete;
  final int done;
  final bool consented;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpace.radius),
        onTap: onTap,
        onLongPress: onDelete,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                child: Text(
                  athlete.name.isEmpty ? '?' : athlete.name.characters.first.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.primary),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(athlete.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '${athlete.age} ${l.t('years')}',
                        athlete.gender,
                        if (athlete.school.isNotEmpty) athlete.school,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        StatusPill(
                          label: l.t('roster_progress', {'done': done}),
                          color: done >= 10 ? AppColors.pass : AppColors.primary,
                        ),
                        StatusPill(
                          label: l.t(consented ? 'consent_ok' : 'consent_missing'),
                          color: consented ? AppColors.pass : AppColors.warning,
                          icon: consented ? Icons.verified_user_outlined : Icons.lock_outline_rounded,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              trailing ?? const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
