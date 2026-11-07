import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../localization/l10n.dart';
import '../permissions/permission_service.dart';
import '../theme/app_theme.dart';

/// Persistent utility bar: Offline • SQLCipher Encrypted | free storage | EN | हिं.
class TopStatusBar extends ConsumerWidget {
  const TopStatusBar({super.key, this.dark = false});

  /// Dark variant used over the camera viewport.
  final bool dark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final free = ref.watch(freeStorageProvider).valueOrNull;
    final low = free != null && free < StorageProbe.lowThresholdBytes;
    final fg = dark ? Colors.white : AppColors.text;
    final muted = dark ? Colors.white70 : AppColors.textMuted;

    return Material(
      color: dark ? AppColors.hudBackdrop : AppColors.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: dark ? Colors.white12 : const Color(0xFFE2E8F0)),
          ),
        ),
        padding: const EdgeInsets.only(left: AppSpace.md, right: AppSpace.xs),
        height: 44,
        child: Row(
          children: [
            const Icon(Icons.cloud_off_rounded, size: 16, color: AppColors.pass),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '${l.t('status_offline')} • ${l.t('status_encrypted')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            if (free != null)
              Tooltip(
                message: low ? l.t('status_low_storage') : '',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      low ? Icons.warning_amber_rounded : Icons.sd_storage_outlined,
                      size: 16,
                      color: low ? AppColors.warning : muted,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      formatBytes(free),
                      style: AppText.metricS.copyWith(
                        fontSize: 12,
                        color: low ? AppColors.warning : muted,
                      ),
                    ),
                  ],
                ),
              ),
            const Spacer(),
            _LangToggle(dark: dark),
          ],
        ),
      ),
    );
  }
}

class _LangToggle extends ConsumerWidget {
  const _LangToggle({required this.dark});
  final bool dark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang = ref.watch(langProvider);
    return Semantics(
      button: true,
      label: 'Language / भाषा',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => ref.read(langProvider.notifier).toggle(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpace.touch, minWidth: 84),
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: dark ? Colors.white24 : AppColors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final l in AppLang.values)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: l == lang ? AppColors.primary : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        l.short,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: l == lang
                              ? Colors.white
                              : (dark ? Colors.white70 : AppColors.textMuted),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
