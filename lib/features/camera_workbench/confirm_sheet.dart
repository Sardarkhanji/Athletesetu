import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/domain/sai_test.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';
import '../../engines/pose_types.dart';

enum ConfirmAction { confirm, override, discard }

class ConfirmDecision {
  const ConfirmDecision(this.action, {this.value, this.reason});
  final ConfirmAction action;
  final double? value;
  final String? reason;
}

/// After every attempt: AI score + confidence, then Confirm & Save or Manual Override.
Future<ConfirmDecision?> showConfirmSheet(
  BuildContext context, {
  required AttemptOutcome outcome,
  required int attemptNo,
  Map<String, Object?> groundTruth = const {},
  bool simulated = false,
  double? bmiValue,
}) =>
    showModalBottomSheet<ConfirmDecision>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useSafeArea: true,
      builder: (_) => _ConfirmSheet(
        outcome: outcome,
        attemptNo: attemptNo,
        groundTruth: groundTruth,
        simulated: simulated,
        bmiValue: bmiValue,
      ),
    );

class _ConfirmSheet extends ConsumerStatefulWidget {
  const _ConfirmSheet({
    required this.outcome,
    required this.attemptNo,
    required this.groundTruth,
    required this.simulated,
    this.bmiValue,
  });

  final AttemptOutcome outcome;
  final int attemptNo;
  final Map<String, Object?> groundTruth;
  final bool simulated;
  final double? bmiValue;

  @override
  ConsumerState<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends ConsumerState<_ConfirmSheet> {
  bool _overriding = false;
  final _value = TextEditingController();
  String _reason = 'reason_tape';
  String? _error;

  static const _reasons = [
    'reason_tape',
    'reason_occlusion',
    'reason_wrong_frame',
    'reason_calibration',
    'reason_foul_missed',
  ];

  SaiTest get test => widget.outcome.test;

  @override
  void initState() {
    super.initState();
    _overriding = widget.outcome.value == null;
    if (widget.outcome.value != null) _value.text = test.format(widget.outcome.value);
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  double? _parse() {
    final raw = _value.text.trim().replaceAll(',', '.');
    // Endurance may be typed as m:ss.s
    if (raw.contains(':')) {
      final parts = raw.split(':');
      final m = int.tryParse(parts[0]), s = double.tryParse(parts[1]);
      return m == null || s == null ? null : m * 60 + s;
    }
    return double.tryParse(raw);
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(l10nProvider);
    final o = widget.outcome;
    final text = Theme.of(context).textTheme;
    final truth = _truthLine();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${l.testName(test)} · #${widget.attemptNo}', style: text.titleLarge),
                ),
                if (widget.simulated) StatusPill(label: l.t('simulated'), color: AppColors.primary, icon: Icons.science_outlined),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.t('sheet_ai_score'), style: const TextStyle(color: AppColors.textMuted)),
                      Text.rich(TextSpan(children: [
                        TextSpan(text: test.format(o.value), style: AppText.metricXL),
                        TextSpan(text: ' ${l.unit(test)}', style: AppText.metricM.copyWith(color: AppColors.textMuted)),
                      ])),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(l.t('sheet_confidence'), style: const TextStyle(color: AppColors.textMuted)),
                    const SizedBox(height: 4),
                    ConfidenceBadge(confidence: o.confidence),
                  ],
                ),
              ],
            ),
            if (widget.bmiValue != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(l.t('wb_bmi', {'bmi': widget.bmiValue!.toStringAsFixed(1)}), style: AppText.metricM),
            ],
            if (o.fouls.isNotEmpty) ...[
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final f in o.fouls)
                    StatusPill(label: l.t(f), color: AppColors.foul, icon: Icons.flag_outlined),
                ],
              ),
            ],
            const SizedBox(height: AppSpace.sm),
            _Details(metadata: o.metadata, truthLine: truth),
            const SizedBox(height: AppSpace.md),
            if (!_overriding) ...[
              PrimaryButton(
                label: l.t('sheet_confirm'),
                icon: Icons.check_rounded,
                color: AppColors.pass,
                onPressed: o.value == null
                    ? null
                    : () => Navigator.pop(context, ConfirmDecision(ConfirmAction.confirm, value: o.value)),
              ),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton.icon(
                onPressed: () => setState(() => _overriding = true),
                icon: const Icon(Icons.edit_outlined),
                label: Text(l.t('sheet_override')),
              ),
            ] else ...[
              TextField(
                controller: _value,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,:]'))],
                style: AppText.metricM,
                decoration: InputDecoration(
                  labelText: l.t('sheet_manual_value', {'unit': l.unit(test)}),
                  errorText: _error,
                ),
              ),
              const SizedBox(height: AppSpace.md),
              Text(l.t('sheet_reason'), style: text.titleSmall),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in _reasons)
                    ChoiceChip(
                      label: Text(l.t(r)),
                      selected: _reason == r,
                      onSelected: (_) => setState(() => _reason = r),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              PrimaryButton(
                label: l.t('sheet_save_override'),
                icon: Icons.save_outlined,
                color: AppColors.warning,
                onPressed: () {
                  final v = _parse();
                  if (v == null || v < 0) {
                    setState(() => _error = l.t('sheet_invalid_number'));
                    return;
                  }
                  Navigator.pop(context, ConfirmDecision(ConfirmAction.override, value: v, reason: _reason));
                },
              ),
              if (o.value != null)
                TextButton(
                  onPressed: () => setState(() => _overriding = false),
                  child: Text(l.t('cancel')),
                ),
            ],
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.foul),
              onPressed: () => Navigator.pop(context, const ConfirmDecision(ConfirmAction.discard)),
              child: Text(l.t('sheet_discard')),
            ),
          ],
        ),
      ),
    );
  }

  String? _truthLine() {
    if (!widget.simulated || widget.groundTruth.isEmpty) return null;
    final t = widget.groundTruth;
    final v = t['trueHeightCm'] ??
        t['trueReachDeltaCm'] ??
        t['trueDistanceCm'] ??
        t['trueBestReachCm'] ??
        t['trueTimeS'] ??
        t['expectedValidReps'] ??
        t['trueKg'];
    if (v == null) return null;
    return 'Simulator truth: ${test.format((v as num).toDouble())} ${test.unit}';
  }
}

class _Details extends ConsumerWidget {
  const _Details({required this.metadata, this.truthLine});
  final Map<String, Object?> metadata;
  final String? truthLine;

  static const _shown = {
    'validReps', 'attemptedReps', 'rejectedReps', 'spatialDeltaCm', 'flightTimeMs', 'flightHeightCm',
    'standingReachCm', 'disagreementCm', 'stdCm', 'method', 'settleSpreadCm', 'heelOffsetCm', 'mode',
    'missedTouches', 'lapSplitsS', 'ocrText', 'aiProposedCm', 'scrubAdjustCm', 'fitResidualPx', 'bmi',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(l10nProvider);
    final rows = metadata.entries.where((e) => _shown.contains(e.key) && e.value != null).toList();
    if (rows.isEmpty && truthLine == null) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: AppSpace.sm),
        title: Text(l.t('sheet_details'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        initiallyExpanded: truthLine != null,
        children: [
          if (truthLine != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(truthLine!, style: AppText.metricS.copyWith(color: AppColors.primary)),
              ),
            ),
          for (final e in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(e.key, style: const TextStyle(fontSize: 13, color: AppColors.textMuted))),
                  Flexible(child: Text('${e.value}', textAlign: TextAlign.end, style: AppText.metricS.copyWith(color: AppColors.text))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
