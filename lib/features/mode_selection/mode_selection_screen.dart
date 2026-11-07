import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/database/app_database.dart';
import '../../core/domain/entities.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';

/// Persisted assessment mode.
class AppModeNotifier extends Notifier<AppMode> {
  static const _key = 'app_mode';

  @override
  AppMode build() {
    final v = ref.read(appDatabaseProvider).cachedSetting(_key);
    return AppMode.values.firstWhere((m) => m.name == v, orElse: () => AppMode.coachAthleteWise);
  }

  Future<void> set(AppMode m) async {
    state = m;
    await ref.read(appDatabaseProvider).setSetting(_key, m.name);
  }
}

final appModeProvider = NotifierProvider<AppModeNotifier, AppMode>(AppModeNotifier.new);

class ModeSelectionScreen extends ConsumerWidget {
  const ModeSelectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final current = ref.watch(appModeProvider);

    void choose(AppMode m) {
      ref.read(appModeProvider.notifier).set(m);
      context.push(m == AppMode.coachStationWise ? Routes.stations : Routes.roster);
    }

    return AppScaffold(
      showBack: false,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.lg, AppSpace.md, AppSpace.xl),
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppSpace.radius),
                ),
                child: const Icon(Icons.directions_run_rounded, color: Colors.white, size: 30),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.t('app_name'), style: Theme.of(context).textTheme.headlineSmall),
                    Text(l.t('app_tagline'), style: const TextStyle(color: AppColors.textMuted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xl),
          Text(l.t('mode_title'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpace.md),
          _ModeCard(
            icon: Icons.person_rounded,
            title: l.t('mode_individual'),
            body: l.t('mode_individual_desc'),
            selected: current == AppMode.individual,
            onTap: () => choose(AppMode.individual),
          ),
          const SizedBox(height: AppSpace.md),
          _ModeCard(
            icon: Icons.groups_rounded,
            title: l.t('mode_coach_athlete'),
            body: l.t('mode_coach_athlete_desc'),
            selected: current == AppMode.coachAthleteWise,
            onTap: () => choose(AppMode.coachAthleteWise),
          ),
          const SizedBox(height: AppSpace.md),
          _ModeCard(
            icon: Icons.grid_view_rounded,
            title: l.t('mode_coach_station'),
            body: l.t('mode_coach_station_desc'),
            selected: current == AppMode.coachStationWise,
            onTap: () => choose(AppMode.coachStationWise),
          ),
          const SizedBox(height: AppSpace.lg),
          OutlinedButton.icon(
            onPressed: () => context.push(Routes.reports),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: Text(l.t('mode_reports')),
          ),
          const SizedBox(height: AppSpace.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.verified_user_outlined, size: 18, color: AppColors.pass),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  l.t('mode_privacy_note'),
                  style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpace.radius),
        side: BorderSide(
          color: selected ? AppColors.primary : const Color(0xFFE2E8F0),
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpace.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            children: [
              Icon(icon, size: 32, color: AppColors.primary),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(body, style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
