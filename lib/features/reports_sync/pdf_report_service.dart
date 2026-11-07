import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/database/repository.dart';
import '../../core/domain/entities.dart';
import '../../core/domain/sai_test.dart';
import '../../core/localization/l10n.dart';
import '../../engines/assisted_ocr_engine.dart' show bmi;

/// Offline bilingual (English / हिंदी) PDF report.
///
/// The `pdf` package has no OpenType shaping for Indic scripts (conjuncts and
/// matras would render broken), so every Hindi string is laid out by
/// Flutter's own text engine with the bundled Noto Sans Devanagari font and
/// embedded as a crisp 3× image. Latin text uses embedded Noto Sans.
class PdfReportService {
  PdfReportService(this.l10n);
  final L10n l10n;

  static const _scale = 3.0;
  static const _ink = PdfColor.fromInt(0xFF0F172A);
  static const _muted = PdfColor.fromInt(0xFF475569);
  static const _primary = PdfColor.fromInt(0xFF2563EB);
  static const _line = PdfColor.fromInt(0xFFE2E8F0);

  Future<pw.Widget> _hi(String text, {double size = 9, bool bold = false, Color color = const Color(0xFF475569)}) async {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: 'NotoSansDevanagari',
      fontSize: size * _scale,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    ))
      ..pushStyle(ui.TextStyle(
        color: color,
        fontFamily: 'NotoSansDevanagari',
        fontFamilyFallback: const ['NotoSans'],
        fontSize: size * _scale,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      ))
      ..addText(text);
    final para = builder.build()..layout(const ui.ParagraphConstraints(width: 6000));
    final w = para.longestLine.ceil() + 2, h = para.height.ceil() + 2;
    final rec = ui.PictureRecorder();
    Canvas(rec).drawParagraph(para, const Offset(1, 1));
    final image = await rec.endRecording().toImage(w, h);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return pw.Image(pw.MemoryImage(png!.buffer.asUint8List()), width: w / _scale, height: h / _scale);
  }

  /// English line with its Hindi rendering underneath.
  Future<pw.Widget> _bi(String key, {double size = 9, bool bold = false, Map<String, Object?> params = const {}}) async {
    final en = l10n.en(key, params), hi = l10n.hi(key, params);
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Text(en, style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: _ink)),
        if (hi != en) await _hi(hi, size: size * 0.92, bold: bold),
      ],
    );
  }

  Future<Uint8List> build({
    required Athlete athlete,
    required List<TestResult> results,
    required ConsentRecord? consent,
  }) async {
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'));
    final best = bestByTest(results);
    final attempts = <SaiTest, int>{};
    for (final r in results) {
      attempts[r.test] = (attempts[r.test] ?? 0) + 1;
    }
    final height = best[SaiTest.height]?.finalScore ?? athlete.heightCm;
    final weight = best[SaiTest.weight]?.finalScore;
    final now = DateTime.now();
    String date(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

    // Pre-render every bilingual cell (async) before laying out the page.
    final title = await _bi('pdf_title', size: 18, bold: true);
    final headers = [
      await _bi('pdf_test', bold: true),
      await _bi('pdf_result', bold: true),
      await _bi('pdf_confidence', bold: true),
      await _bi('pdf_method', bold: true),
    ];
    final testCells = {for (final t in SaiTest.values) t: await _bi(t.nameKey)};
    final infoLabels = {
      for (final k in ['reg_name', 'reg_dob', 'reg_gender', 'reg_school', 'reg_district', 'reg_state'])
        k: await _bi(k, size: 8),
    };
    final consentLabel = await _bi('pdf_consent', bold: true);
    final footer = await _bi('pdf_footer', size: 7.5);
    final generated = await _bi('pdf_generated', size: 7.5, params: {'date': date(now)});
    final manual = await _bi('pdf_method_manual', size: 8);
    final ai = await _bi('pdf_method_ai', size: 8);

    final doc = pw.Document(
      title: 'AthleteSetu report — ${athlete.name}',
      author: 'AthleteSetu (offline)',
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );

    pw.Widget cell(pw.Widget child, {bool header = false}) => pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          color: header ? const PdfColor.fromInt(0xFFF1F5F9) : null,
          child: child,
        );
    pw.Widget txt(String s, {bool b = false, PdfColor c = _ink, double size = 9}) =>
        pw.Text(s, style: pw.TextStyle(fontSize: size, fontWeight: b ? pw.FontWeight.bold : pw.FontWeight.normal, color: c));

    final genderKey = switch (athlete.gender) { 'F' => 'reg_female', 'O' => 'reg_other', _ => 'reg_male' };
    final infoRows = <(String, String)>[
      ('reg_name', athlete.name),
      ('reg_dob', '${date(athlete.dob)} (${athlete.age})'),
      ('reg_gender', l10n.bi(genderKey)),
      ('reg_school', athlete.school.isEmpty ? '—' : athlete.school),
      ('reg_district', athlete.district.isEmpty ? '—' : athlete.district),
      ('reg_state', athlete.state.isEmpty ? '—' : athlete.state),
    ];
    // Gender value contains Hindi: render it as image.
    final genderValue = await _hi(l10n.hi(genderKey), size: 9, color: const Color(0xFF0F172A));

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 40),
      footer: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Divider(color: _line),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(child: footer),
              txt('${ctx.pageNumber}/${ctx.pagesCount}', c: _muted, size: 8),
            ],
          ),
        ],
      ),
      build: (ctx) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: title),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              txt('AthleteSetu', b: true, c: _primary, size: 12),
              txt('ID ${athlete.id}', c: _muted, size: 7),
            ]),
          ],
        ),
        pw.SizedBox(height: 4),
        generated,
        pw.SizedBox(height: 14),
        pw.Table(
          border: pw.TableBorder.all(color: _line, width: 0.6),
          columnWidths: const {0: pw.FlexColumnWidth(1.1), 1: pw.FlexColumnWidth(2)},
          children: [
            for (final (k, v) in infoRows)
              pw.TableRow(children: [
                cell(infoLabels[k]!, header: true),
                cell(k == 'reg_gender'
                    ? pw.Row(children: [txt('${l10n.en(genderKey)} / '), genderValue])
                    : txt(v, b: k == 'reg_name')),
              ]),
          ],
        ),
        pw.SizedBox(height: 16),
        pw.Table(
          border: pw.TableBorder.all(color: _line, width: 0.6),
          columnWidths: const {
            0: pw.FlexColumnWidth(2.2),
            1: pw.FlexColumnWidth(1.3),
            2: pw.FlexColumnWidth(1),
            3: pw.FlexColumnWidth(1.1),
          },
          children: [
            pw.TableRow(children: [for (final h in headers) cell(h, header: true)]),
            for (final t in SaiTest.values)
              pw.TableRow(children: [
                cell(testCells[t]!),
                cell(best[t] == null
                    ? txt('—', c: _muted)
                    : pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                        txt('${t.format(best[t]!.finalScore)} ${t.unit}', b: true, size: 10),
                        txt('${attempts[t] ?? 0}/${t.attempts} · ${t.toleranceLabel}', c: _muted, size: 7),
                      ])),
                cell(best[t] == null ? txt('—', c: _muted) : txt('${best[t]!.confidence.round()}%')),
                cell(best[t] == null
                    ? txt('—', c: _muted)
                    : pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                        best[t]!.isOverride ? manual : ai,
                        if (best[t]!.simulated) txt('SIM', c: _primary, size: 7, b: true),
                      ])),
              ]),
          ],
        ),
        if (weight != null && height != null) ...[
          pw.SizedBox(height: 10),
          txt('BMI: ${bmi(weight, height).toStringAsFixed(1)} kg/m²  (${weight.toStringAsFixed(1)} kg, ${height.toStringAsFixed(1)} cm)', b: true),
        ],
        pw.SizedBox(height: 16),
        consentLabel,
        pw.SizedBox(height: 4),
        if (consent == null)
          txt('—', c: _muted)
        else
          txt(
            consent.isMinor
                ? 'Guardian consent: ${consent.guardianName} (${l10n.en(consent.guardianRelation ?? '')}) · signed form photo on file · ${date(consent.grantedAt)} · ${consent.consentVersion}'
                : 'Self consent (adult) · ${date(consent.grantedAt)} · ${consent.consentVersion}',
            c: _muted,
            size: 8,
          ),
      ],
    ));
    return doc.save();
  }
}

/// Builds, saves and shares an athlete's report, then marks their data as synced.
Future<void> exportAthletePdf(BuildContext context, WidgetRef ref, Athlete athlete) async {
  final l = ref.read(l10nProvider);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text(l.t('reports_exporting')), duration: const Duration(seconds: 1)));
  try {
    final repo = ref.read(repositoryProvider);
    final bytes = await PdfReportService(l).build(
      athlete: athlete,
      results: await repo.results(athlete.id),
      consent: await repo.latestConsent(athlete.id),
    );
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'reports'));
    await dir.create(recursive: true);
    final safe = athlete.name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final name = 'AthleteSetu_${safe}_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    await repo.markAthleteSynced(athlete.id);
    messenger.showSnackBar(SnackBar(content: Text(l.t('reports_exported', {'path': name}))));
    await Printing.sharePdf(bytes: bytes, filename: name);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(l.t('error_generic', {'msg': e}))));
  }
}
