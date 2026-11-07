import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/database/repository.dart';
import '../../core/domain/entities.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';
import 'consent_form.dart';

/// Two steps: athlete details → DPDP consent. Nothing is saved until consent is valid.
class RegistrationScreen extends ConsumerStatefulWidget {
  const RegistrationScreen({super.key, this.returnToStation});

  /// Station-wise mode: return to this station's queue afterwards.
  final String? returnToStation;

  @override
  ConsumerState<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends ConsumerState<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _school = TextEditingController();
  final _district = TextEditingController();
  final _state = TextEditingController();
  final _athleteId = newId('a_');
  DateTime? _dob;
  String _gender = 'M';
  int _step = 0;
  ConsentRecord? _consent;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _school, _district, _state]) {
      c.dispose();
    }
    super.dispose();
  }

  Athlete get _draft => Athlete(
        id: _athleteId,
        name: _name.text.trim(),
        dob: _dob ?? DateTime(2010),
        gender: _gender,
        school: _school.text.trim(),
        district: _district.text.trim(),
        state: _state.text.trim(),
        createdAt: DateTime.now(),
      );

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 12, now.month, now.day),
      firstDate: DateTime(now.year - 70),
      lastDate: DateTime(now.year - 5, now.month, now.day),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _save() async {
    final consent = _consent;
    if (consent == null) return;
    setState(() => _saving = true);
    final l = ref.read(l10nProvider);
    try {
      await ref.read(repositoryProvider).insertAthleteWithConsent(_draft, consent);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('consent_saved'))));
      if (widget.returnToStation != null) {
        context.pop();
      } else {
        context.pushReplacement(Routes.athlete(_athleteId));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.t('error_generic', {'msg': e}))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(l10nProvider);
    final draft = _draft;
    final hasDob = _dob != null;

    return AppScaffold(
      title: _step == 0 ? l.t('reg_title') : l.t('consent_title'),
      onBack: _step == 1 ? () => setState(() => _step = 0) : null,
      bottom: _step == 0
          ? PrimaryButton(
              label: l.t('reg_continue_consent'),
              icon: Icons.arrow_forward_rounded,
              onPressed: () {
                if ((_formKey.currentState?.validate() ?? false) && hasDob) {
                  setState(() => _step = 1);
                } else if (!hasDob) {
                  _pickDob();
                }
              },
            )
          : PrimaryButton(
              label: l.t('consent_record'),
              icon: Icons.verified_user_rounded,
              busy: _saving,
              onPressed: _consent == null ? null : _save,
            ),
      body: _step == 0 ? _details(l, draft, hasDob) : _consentStep(l, draft),
    );
  }

  Widget _details(L10n l, Athlete draft, bool hasDob) {
    String? req(String? v) => (v == null || v.trim().isEmpty) ? l.t('required') : null;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpace.md),
        children: [
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: '${l.t('reg_name')} *'),
            validator: req,
          ),
          const SizedBox(height: AppSpace.md),
          InkWell(
            borderRadius: BorderRadius.circular(AppSpace.radius),
            onTap: _pickDob,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: '${l.t('reg_dob')} *',
                suffixIcon: const Icon(Icons.calendar_today_outlined),
              ),
              child: Text(
                hasDob
                    ? '${_dob!.day.toString().padLeft(2, '0')}/${_dob!.month.toString().padLeft(2, '0')}/${_dob!.year}'
                    : '—',
                style: AppText.tabular(const TextStyle(fontSize: 16)),
              ),
            ),
          ),
          if (hasDob) ...[
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                StatusPill(label: l.t('reg_age_is', {'age': draft.age}), color: AppColors.primary),
                if (draft.isMinor)
                  StatusPill(
                    label: l.t('reg_minor_badge'),
                    color: AppColors.warning,
                    icon: Icons.family_restroom_rounded,
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpace.md),
          Text(l.t('reg_gender'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpace.sm),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'M', label: Text(l.t('reg_male'))),
              ButtonSegment(value: 'F', label: Text(l.t('reg_female'))),
              ButtonSegment(value: 'O', label: Text(l.t('reg_other'))),
            ],
            selected: {_gender},
            onSelectionChanged: (s) => setState(() => _gender = s.first),
          ),
          const SizedBox(height: AppSpace.md),
          TextFormField(controller: _school, decoration: InputDecoration(labelText: l.t('reg_school'))),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                child: TextFormField(controller: _district, decoration: InputDecoration(labelText: l.t('reg_district'))),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: TextFormField(controller: _state, decoration: InputDecoration(labelText: l.t('reg_state'))),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
        ],
      ),
    );
  }

  Widget _consentStep(L10n l, Athlete draft) => ListView(
        padding: const EdgeInsets.all(AppSpace.md),
        children: [
          Text(draft.name, style: Theme.of(context).textTheme.titleLarge),
          Text(l.t('reg_age_is', {'age': draft.age}), style: const TextStyle(color: AppColors.textMuted)),
          const SizedBox(height: AppSpace.md),
          ConsentForm(
            athleteId: _athleteId,
            isMinor: draft.isMinor,
            onChanged: (c) => setState(() => _consent = c),
          ),
          const SizedBox(height: AppSpace.lg),
        ],
      );
}
