import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/domain/entities.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common_widgets.dart';

const kConsentVersion = 'DPDP-2023-v1';
const kConsentPurposes = ['assessment', 'video_analysis', 'report'];

/// DPDP Act 2023 consent capture. Adults tick one box; minors need a guardian
/// name, relationship and a photo of the physically signed consent form.
class ConsentForm extends ConsumerStatefulWidget {
  const ConsentForm({
    super.key,
    required this.athleteId,
    required this.isMinor,
    required this.onChanged,
  });

  final String athleteId;
  final bool isMinor;

  /// Emits a complete, valid record or null while the form is incomplete.
  final ValueChanged<ConsentRecord?> onChanged;

  @override
  ConsumerState<ConsentForm> createState() => _ConsentFormState();
}

class _ConsentFormState extends ConsumerState<ConsentForm> {
  final _guardian = TextEditingController();
  String? _relation;
  String? _photoPath;
  bool _agreed = false;
  bool _capturing = false;

  static const _relations = ['rel_father', 'rel_mother', 'rel_guardian', 'rel_teacher'];

  @override
  void dispose() {
    _guardian.dispose();
    super.dispose();
  }

  void _emit() {
    final record = ConsentRecord(
      id: newId('c_'),
      athleteId: widget.athleteId,
      isMinor: widget.isMinor,
      guardianName: widget.isMinor ? _guardian.text.trim() : null,
      guardianRelation: widget.isMinor ? _relation : null,
      consentFormPath: widget.isMinor ? _photoPath : null,
      consentVersion: kConsentVersion,
      purposes: kConsentPurposes,
      grantedAt: DateTime.now(),
    );
    widget.onChanged(_agreed && record.isValid ? record : null);
  }

  Future<void> _capture() async {
    final l = ref.read(l10nProvider);
    setState(() => _capturing = true);
    try {
      final picker = ImagePicker();
      XFile? shot;
      try {
        shot = await picker.pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2000);
      } catch (_) {
        // No camera (some emulators): fall back to the gallery.
        shot = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2000);
      }
      if (shot == null) return;
      final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'consent'));
      await dir.create(recursive: true);
      final dest = p.join(dir.path, '${widget.athleteId}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(shot.path).copy(dest);
      setState(() => _photoPath = dest);
      _emit();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.t('consent_photo_failed', {'msg': e}))),
        );
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(l10nProvider);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.t('consent_intro'), style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpace.sm),
                for (final k in ['consent_purpose_assessment', 'consent_purpose_video', 'consent_purpose_report'])
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(Icons.check_circle_outline, size: 18, color: AppColors.pass),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(child: Text(l.t(k))),
                      ],
                    ),
                  ),
                const SizedBox(height: AppSpace.md),
                Text(l.t('consent_rights'), style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
              ],
            ),
          ),
        ),
        if (widget.isMinor) ...[
          const SizedBox(height: AppSpace.md),
          Container(
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppSpace.radius),
              border: Border.all(color: AppColors.warning),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.family_restroom_rounded, color: AppColors.warning),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(child: Text(l.t('consent_minor_heading'), style: text.titleMedium)),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                Text(l.t('consent_minor_body'), style: const TextStyle(fontSize: 13)),
                const SizedBox(height: AppSpace.md),
                TextField(
                  controller: _guardian,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: '${l.t('consent_guardian_name')} *'),
                  onChanged: (_) => _emit(),
                ),
                const SizedBox(height: AppSpace.md),
                DropdownButtonFormField<String>(
                  initialValue: _relation,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: '${l.t('consent_relation')} *'),
                  items: [
                    for (final r in _relations) DropdownMenuItem(value: r, child: Text(l.t(r))),
                  ],
                  onChanged: (v) {
                    setState(() => _relation = v);
                    _emit();
                  },
                ),
                const SizedBox(height: AppSpace.md),
                if (_photoPath != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppSpace.radius),
                    child: Image.file(File(_photoPath!), height: 160, fit: BoxFit.cover),
                  ),
                if (_photoPath != null) const SizedBox(height: AppSpace.sm),
                OutlinedButton.icon(
                  onPressed: _capturing ? null : _capture,
                  icon: Icon(_photoPath == null ? Icons.photo_camera_outlined : Icons.refresh_rounded),
                  label: Text(l.t(_photoPath == null ? 'consent_capture_form' : 'consent_retake_form')),
                ),
                if (_photoPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.sm),
                    child: StatusPill(
                      label: l.t('consent_form_captured'),
                      color: AppColors.pass,
                      icon: Icons.check_rounded,
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpace.md),
        Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpace.radius),
            side: BorderSide(color: _agreed ? AppColors.primary : AppColors.border),
          ),
          child: CheckboxListTile(
            value: _agreed,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 4),
            title: Text(l.t(widget.isMinor ? 'consent_guardian_check' : 'consent_adult_check')),
            onChanged: (v) {
              setState(() => _agreed = v ?? false);
              _emit();
            },
          ),
        ),
      ],
    );
  }
}
