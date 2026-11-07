import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../localization/l10n.dart';
import '../permissions/permission_service.dart';
import '../theme/app_theme.dart';
import 'top_status_bar.dart';

/// Standard page: utility bar on top, optional app bar, bottom-anchored action.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    required this.body,
    this.title,
    this.actions,
    this.bottom,
    this.showBack = true,
    this.onBack,
  });

  final String? title;
  final Widget body;
  final List<Widget>? actions;

  /// Bottom-anchored primary action(s).
  final Widget? bottom;
  final bool showBack;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const TopStatusBar(),
            if (title != null)
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    if (showBack && (canPop || onBack != null))
                      IconButton(
                        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                      )
                    else
                      const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Text(
                        title!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    ...?actions,
                    const SizedBox(width: AppSpace.xs),
                  ],
                ),
              ),
            Expanded(child: body),
          ],
        ),
      ),
      bottomNavigationBar: bottom == null
          ? null
          : Material(
              color: AppColors.surface,
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.sm, AppSpace.md, AppSpace.sm),
                    child: bottom,
                  ),
                ),
              ),
            ),
    );
  }
}

/// Full-width bottom-anchored primary button (≥52 px tall).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
          )
        : Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    return SizedBox(
      width: double.infinity,
      child: icon == null || busy
          ? FilledButton(
              style: color == null ? null : FilledButton.styleFrom(backgroundColor: color),
              onPressed: busy ? null : onPressed,
              child: child,
            )
          : FilledButton.icon(
              style: color == null ? null : FilledButton.styleFrom(backgroundColor: color),
              onPressed: onPressed,
              icon: Icon(icon),
              label: child,
            ),
    );
  }
}

/// 0–100 confidence chip: ≥85 emerald, ≥60 amber, else crimson.
class ConfidenceBadge extends ConsumerWidget {
  const ConfidenceBadge({super.key, required this.confidence, this.compact = false});

  final double confidence;
  final bool compact;

  static Color colorFor(double c) =>
      c >= 85 ? AppColors.pass : (c >= 60 ? AppColors.warning : AppColors.foul);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final color = colorFor(confidence);
    final label = confidence >= 85
        ? l.t('conf_high')
        : (confidence >= 60 ? l.t('conf_medium') : l.t('conf_low'));
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        compact ? '${confidence.round()}%' : '${confidence.round()}% · $label',
        style: AppText.tabular(TextStyle(
          fontSize: compact ? 11 : 13,
          fontWeight: FontWeight.w700,
          color: color,
        )),
      ),
    );
  }
}

/// Small pill label.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.lg, AppSpace.md, AppSpace.sm),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w700,
            color: AppColors.textMuted,
          ),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: AppColors.border),
              const SizedBox(height: AppSpace.md),
              Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
            ],
          ),
        ),
      );
}

/// Shows the <500 MB warning before starting a test. Returns true to proceed.
Future<bool> confirmStorageBeforeTest(BuildContext context, WidgetRef ref) async {
  ref.invalidate(freeStorageProvider);
  final free = await ref.read(freeStorageProvider.future);
  if (free == null || free >= StorageProbe.lowThresholdBytes) return true;
  if (!context.mounted) return false;
  final l = ref.read(l10nProvider);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 36),
      title: Text(l.t('storage_warning_title')),
      content: Text(l.t('storage_warning_body', {'size': formatBytes(free)})),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.t('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.t('continue_anyway'))),
      ],
    ),
  );
  return ok ?? false;
}

class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({super.key, required this.value, required this.data});
  final AsyncValue<T> value;
  final Widget Function(T data) data;

  @override
  Widget build(BuildContext context) => value.when(
        data: data,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Text('$e', style: const TextStyle(color: AppColors.foul)),
          ),
        ),
      );
}
