import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../domain/entities.dart';
import '../domain/sai_test.dart';
import 'app_database.dart';

/// Bumped after every write; read-side providers watch it to refresh.
class DataRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final dataRevisionProvider = NotifierProvider<DataRevision, int>(DataRevision.new);

class VideoStats {
  const VideoStats({
    required this.count,
    required this.bytes,
    required this.syncedCount,
    required this.syncedBytes,
  });
  final int count;
  final int bytes;
  final int syncedCount;
  final int syncedBytes;
}

class RecycleBinItem {
  const RecycleBinItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.deletedAt,
  });

  /// 'athlete' | 'result'
  final String kind;
  final String id;
  final String title;
  final String subtitle;
  final DateTime deletedAt;

  int daysLeft(DateTime now) =>
      AppDatabase.recycleBinDays - now.difference(deletedAt).inDays;
}

/// All DAO operations. Multi-row writes run inside a single transaction (atomic under WAL).
class Repository {
  Repository(this._appDb, this._onChange);

  final AppDatabase _appDb;
  final void Function() _onChange;

  Database get _db => _appDb.db;

  // ---------------- Athletes ----------------

  Future<void> insertAthleteWithConsent(Athlete athlete, ConsentRecord consent) async {
    await _db.transaction((txn) async {
      await txn.insert('athletes', athlete.toRow());
      await txn.insert('consents', consent.toRow());
    });
    _onChange();
  }

  Future<void> insertAthlete(Athlete athlete) async {
    await _db.insert('athletes', athlete.toRow());
    _onChange();
  }

  Future<List<Athlete>> athletes() async {
    final rows = await _db.query('athletes',
        where: 'deleted_at IS NULL', orderBy: 'created_at DESC');
    return rows.map(Athlete.fromRow).toList();
  }

  Future<Athlete?> athlete(String id) async {
    final rows = await _db.query('athletes', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Athlete.fromRow(rows.first);
  }

  Future<void> softDeleteAthlete(String id) async {
    await _db.update('athletes', {'deleted_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
    _onChange();
  }

  // ---------------- Consent (DPDP) ----------------

  Future<void> insertConsent(ConsentRecord consent) async {
    await _db.insert('consents', consent.toRow());
    _onChange();
  }

  Future<ConsentRecord?> latestConsent(String athleteId) async {
    final rows = await _db.query('consents',
        where: 'athlete_id = ?', whereArgs: [athleteId], orderBy: 'granted_at DESC', limit: 1);
    return rows.isEmpty ? null : ConsentRecord.fromRow(rows.first);
  }

  Future<bool> hasValidConsent(String athleteId) async =>
      (await latestConsent(athleteId))?.isValid ?? false;

  Future<Set<String>> athleteIdsWithValidConsent() async {
    final rows = await _db.query('consents', orderBy: 'granted_at ASC');
    final latest = <String, ConsentRecord>{};
    for (final r in rows) {
      final c = ConsentRecord.fromRow(r);
      latest[c.athleteId] = c;
    }
    return {for (final e in latest.entries) if (e.value.isValid) e.key};
  }

  // ---------------- Results ----------------

  /// Saves a confirmed/overridden attempt atomically together with its optional
  /// training label (for overrides), the recorded video's metadata and, for
  /// height, the athlete's cached height (used for BMI).
  Future<void> saveAttempt({
    required TestResult result,
    TrainingLabel? label,
    VideoRecord? video,
  }) async {
    await _db.transaction((txn) async {
      await txn.insert('test_results', result.toRow());
      if (label != null) await txn.insert('training_labels', label.toRow());
      if (video != null) await txn.insert('videos', video.toRow());
      if (result.test == SaiTest.height) {
        await txn.update('athletes', {'height_cm': result.finalScore},
            where: 'id = ?', whereArgs: [result.athleteId]);
      }
    });
    _onChange();
  }

  Future<List<TestResult>> results(String athleteId) async {
    final rows = await _db.query('test_results',
        where: 'athlete_id = ? AND deleted_at IS NULL',
        whereArgs: [athleteId],
        orderBy: 'created_at ASC');
    return rows.map(TestResult.fromRow).toList();
  }

  /// Results per athlete for one test (station-wise mode).
  Future<Map<String, List<TestResult>>> resultsForTest(SaiTest test) async {
    final rows = await _db.query('test_results',
        where: 'test_id = ? AND deleted_at IS NULL', whereArgs: [test.id]);
    final out = <String, List<TestResult>>{};
    for (final r in rows.map(TestResult.fromRow)) {
      out.putIfAbsent(r.athleteId, () => []).add(r);
    }
    return out;
  }

  /// Number of distinct tests completed per athlete.
  Future<Map<String, int>> completedTestCounts() async {
    final rows = await _db.rawQuery('''
      SELECT athlete_id, COUNT(DISTINCT test_id) AS n FROM test_results
      WHERE deleted_at IS NULL GROUP BY athlete_id''');
    return {for (final r in rows) r['athlete_id'] as String: (r['n'] as int)};
  }

  Future<void> softDeleteResult(String id) async {
    await _db.update('test_results', {'deleted_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
    _onChange();
  }

  /// Marks an athlete's scores and videos as synced (i.e. exported in a report).
  Future<void> markAthleteSynced(String athleteId) async {
    await _db.transaction((txn) async {
      await txn.update('test_results', {'synced': 1}, where: 'athlete_id = ?', whereArgs: [athleteId]);
      await txn.update('videos', {'synced': 1}, where: 'athlete_id = ?', whereArgs: [athleteId]);
    });
    _onChange();
  }

  Future<int> trainingLabelCount() async {
    final r = await _db.rawQuery('SELECT COUNT(*) AS n FROM training_labels');
    return (r.first['n'] as int?) ?? 0;
  }

  // ---------------- Videos (decoupled from scores) ----------------

  Future<VideoStats> videoStats() async {
    final rows = await _db.rawQuery('''
      SELECT COUNT(*) AS n, COALESCE(SUM(size_bytes),0) AS b,
             COALESCE(SUM(CASE WHEN synced = 1 THEN 1 ELSE 0 END),0) AS sn,
             COALESCE(SUM(CASE WHEN synced = 1 THEN size_bytes ELSE 0 END),0) AS sb
      FROM videos WHERE purged_at IS NULL AND deleted_at IS NULL''');
    final r = rows.first;
    return VideoStats(
      count: r['n'] as int,
      bytes: r['b'] as int,
      syncedCount: r['sn'] as int,
      syncedBytes: r['sb'] as int,
    );
  }

  /// 1-tap storage reclaim: deletes synced .mp4 files, keeps every score.
  Future<int> clearSyncedVideos() async {
    final rows = await _db.query('videos',
        where: 'synced = 1 AND purged_at IS NULL AND deleted_at IS NULL');
    var freed = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      for (final r in rows) {
        final v = VideoRecord.fromRow(r);
        try {
          final f = File(v.filePath);
          if (await f.exists()) {
            freed += await f.length();
            await f.delete();
          }
        } catch (_) {
          // File already gone: still mark purged so the row stops counting.
        }
        await txn.update('videos', {'purged_at': now}, where: 'id = ?', whereArgs: [v.id]);
      }
    });
    _onChange();
    return freed;
  }

  // ---------------- Recycle bin ----------------

  Future<List<RecycleBinItem>> recycleBin() async {
    final athletes = await _db.query('athletes',
        where: 'deleted_at IS NOT NULL', orderBy: 'deleted_at DESC');
    final results = await _db.rawQuery('''
      SELECT r.*, a.name AS athlete_name FROM test_results r
      JOIN athletes a ON a.id = r.athlete_id
      WHERE r.deleted_at IS NOT NULL AND a.deleted_at IS NULL
      ORDER BY r.deleted_at DESC''');
    return [
      for (final r in athletes)
        RecycleBinItem(
          kind: 'athlete',
          id: r['id'] as String,
          title: r['name'] as String,
          subtitle: (r['school'] as String?) ?? '',
          deletedAt: DateTime.fromMillisecondsSinceEpoch(r['deleted_at'] as int),
        ),
      for (final r in results)
        RecycleBinItem(
          kind: 'result',
          id: r['id'] as String,
          title: r['athlete_name'] as String,
          subtitle:
              '${SaiTest.fromId(r['test_id'] as String).id} · ${SaiTest.fromId(r['test_id'] as String).format((r['final_score'] as num).toDouble())} ${r['unit']}',
          deletedAt: DateTime.fromMillisecondsSinceEpoch(r['deleted_at'] as int),
        ),
    ];
  }

  Future<void> restore(RecycleBinItem item) async {
    final table = item.kind == 'athlete' ? 'athletes' : 'test_results';
    await _db.update(table, {'deleted_at': null}, where: 'id = ?', whereArgs: [item.id]);
    _onChange();
  }

  Future<void> deleteForever(RecycleBinItem item) async {
    if (item.kind == 'athlete') {
      final files = <String>[
        ...(await _db.query('videos', columns: ['file_path'], where: 'athlete_id = ?', whereArgs: [item.id]))
            .map((r) => r['file_path'] as String),
        ...(await _db.query('consents', columns: ['consent_form_path'], where: 'athlete_id = ?', whereArgs: [item.id]))
            .map((r) => r['consent_form_path'] as String?)
            .whereType<String>(),
      ];
      for (final path in files) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      await _db.delete('athletes', where: 'id = ?', whereArgs: [item.id]);
    } else {
      await _db.delete('test_results', where: 'id = ?', whereArgs: [item.id]);
    }
    _onChange();
  }
}

final repositoryProvider = Provider<Repository>((ref) => Repository(
      ref.watch(appDatabaseProvider),
      () => ref.read(dataRevisionProvider.notifier).bump(),
    ));

// ---------------- Read-side providers ----------------

final athletesProvider = FutureProvider<List<Athlete>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).athletes();
});

final athleteProvider = FutureProvider.family<Athlete?, String>((ref, id) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).athlete(id);
});

final resultsProvider = FutureProvider.family<List<TestResult>, String>((ref, athleteId) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).results(athleteId);
});

final consentProvider = FutureProvider.family<ConsentRecord?, String>((ref, athleteId) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).latestConsent(athleteId);
});

final consentedIdsProvider = FutureProvider<Set<String>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).athleteIdsWithValidConsent();
});

final completedCountsProvider = FutureProvider<Map<String, int>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).completedTestCounts();
});

final stationResultsProvider =
    FutureProvider.family<Map<String, List<TestResult>>, SaiTest>((ref, test) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).resultsForTest(test);
});

final videoStatsProvider = FutureProvider<VideoStats>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).videoStats();
});

final recycleBinProvider = FutureProvider<List<RecycleBinItem>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).recycleBin();
});

final trainingLabelCountProvider = FutureProvider<int>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.watch(repositoryProvider).trainingLabelCount();
});

/// Best valid score per test for an athlete.
Map<SaiTest, TestResult> bestByTest(List<TestResult> results) {
  final best = <SaiTest, TestResult>{};
  for (final r in results) {
    final cur = best[r.test];
    if (cur == null || r.test.isBetter(r.finalScore, cur.finalScore)) best[r.test] = r;
  }
  return best;
}
