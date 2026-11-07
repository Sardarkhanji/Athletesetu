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
import 'consent_form.dart';

/// Shown by the router when a camera test is opened without valid consent.
class ConsentGateScreen extends ConsumerStatefulWidget {
  const ConsentGateScreen({super.key, required this.athleteId, this.nextTestId});

  final String athleteId;
  final String? nextTestId;

  @override
  ConsumerState<ConsentGateScreen> createState() => _ConsentGateScreenState();
}

class _ConsentGateScreenState extends ConsumerState<ConsentGateScreen> {
  ConsentRecord? _consent;
  bool _saving = false;

  Future<void> _save() async {
    final c = _consent;
    if (c == null) return;
    setState(() => _saving = true);
    await ref.read(repositoryProvider).insertConsent(c);
    if (!mounted) return;
    final l = ref.read(l10nProvider);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('consent_saved'))));
    final next = widget.nextTestId;
    if (next != null) {
      context.pushReplacement(Routes.workbench(widget.athleteId, SaiTest.fromId(next)));
    } else {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(l10nProvider);
    final athlete = ref.watch(athleteProvider(widget.athleteId));
    return AppScaffold(
      title: l.t('consent_gate_title'),
      bottom: PrimaryButton(
        label: l.t('consent_record'),
        icon: Icons.verified_user_rounded,
        busy: _saving,
        onPressed: _consent == null ? null : _save,
      ),
      body: AsyncValueView(
        value: athlete,
        data: (a) => a == null
            ? const SizedBox.shrink()
            : ListView(
                padding: const EdgeInsets.all(AppSpace.md),
                children: [
                  Container(
                    padding: const EdgeInsets.all(AppSpace.md),
                    decoration: BoxDecoration(
                      color: AppColors.foul.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AppSpace.radius),
                      border: Border.all(color: AppColors.foul),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_rounded, color: AppColors.foul),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(child: Text(l.t('consent_blocked'))),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  Text(a.name, style: Theme.of(context).textTheme.titleLarge),
                  Text(l.t('reg_age_is', {'age': a.age}), style: const TextStyle(color: AppColors.textMuted)),
                  const SizedBox(height: AppSpace.md),
                  ConsentForm(
                    athleteId: a.id,
                    isMinor: a.isMinor,
                    onChanged: (c) => setState(() => _consent = c),
                  ),
                  const SizedBox(height: AppSpace.lg),
                ],
              ),
      ),
    );
  }
}
