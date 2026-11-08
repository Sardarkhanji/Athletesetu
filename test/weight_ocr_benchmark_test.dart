// Benchmark for the offline seven-segment weight reader on real photos.
// Photos live in test_data/weight/ (git-ignored); see the README there.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:athlete_setu/engines/assisted_ocr_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Same preprocessing as the app (weight_capture_view.dart `_decodeGray`).
GrayImage _loadGray(File f) {
  final decoded = img.decodeImage(f.readAsBytesSync());
  if (decoded == null) throw const FormatException('Unsupported image');
  final upright = img.bakeOrientation(decoded);
  final resized = upright.width > 900 ? img.copyResize(upright, width: 900) : upright;
  final gray = img.grayscale(resized);
  return GrayImage(gray.width, gray.height, gray.getBytes(order: img.ChannelOrder.red));
}

void main() {
  test('weight OCR benchmark on photos in test_data/weight', () {
    final dir = Directory('test_data/weight');
    final files = dir.existsSync()
        ? (dir.listSync().whereType<File>().where((f) => RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false).hasMatch(f.path)).toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
        : <File>[];
    if (files.isEmpty) {
      print('No photos in test_data/weight/ — see test_data/weight/README.md. Skipping.');
      return;
    }

    final nameRe = RegExp(r'^(\d+(?:\.\d+)?)__');
    final rows = <String>['file,expected_kg,read_text,read_kg,confidence,result'];
    var correct = 0, wrong = 0, noRead = 0, unlabeled = 0;
    final confCorrect = <double>[], confWrong = <double>[];

    for (final f in files) {
      final name = f.uri.pathSegments.last;
      final m = nameRe.firstMatch(name);
      if (m == null) {
        unlabeled++;
        print('SKIP  $name (name must start with the true reading, e.g. 72.4__label.jpg)');
        continue;
      }
      final expected = double.parse(m.group(1)!);
      String text = '';
      double? got;
      double conf = 0;
      String result;
      try {
        final o = const WeightOcrEngine().read(_loadGray(f));
        text = '${o.metadata['ocrText'] ?? ''}';
        got = o.value;
        conf = o.confidence;
        if (got == null) {
          result = 'NO_READ';
          noRead++;
        } else if ((got - expected).abs() <= 0.05) {
          result = 'OK';
          correct++;
          confCorrect.add(conf);
        } else {
          result = 'WRONG';
          wrong++;
          confWrong.add(conf);
        }
      } catch (e) {
        result = 'ERROR $e';
        noRead++;
      }
      print('${result.padRight(7)} $name  expected=$expected  read="$text"  conf=${conf.toStringAsFixed(0)}');
      rows.add('"$name",$expected,"$text",${got ?? ''},${conf.toStringAsFixed(1)},$result');
    }

    final n = correct + wrong + noRead;
    double avg(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
    String pct(int k) => n == 0 ? '-' : '${(100 * k / n).toStringAsFixed(1)}%';
    print('');
    print('==== Weight OCR: $n photos ($unlabeled skipped, unlabeled) ====');
    print('Correct (exact to 0.1 kg): $correct  ${pct(correct)}');
    print('Wrong number:              $wrong  ${pct(wrong)}   <- the dangerous case');
    print('No reading (manual entry): $noRead  ${pct(noRead)}');
    print('Mean confidence: correct=${avg(confCorrect).toStringAsFixed(0)}  wrong=${avg(confWrong).toStringAsFixed(0)}');
    File('test_data/weight/results.csv').writeAsStringSync('${rows.join('\n')}\n');
    print('Details: test_data/weight/results.csv');
  });
}
