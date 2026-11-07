import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// AES-256 SQLCipher database.
///
/// * The 256-bit key is generated once with `Random.secure()` and kept in the
///   platform keystore (Android Keystore / iOS Keychain), never in Dart code.
/// * `PRAGMA journal_mode=WAL` keeps writes crash-proof and atomic.
/// * Test **scores** and **video files** live in separate tables, so purging
///   videos never touches scores.
class AppDatabase {
  AppDatabase._(this.db, this._settings);

  final Database db;
  final Map<String, String> _settings;

  static const fileName = 'athletesetu.db';
  static const schemaVersion = 1;
  static const recycleBinDays = 30;
  static const _keyName = 'athletesetu_db_key_v1';

  static Future<AppDatabase> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, fileName);
    final key = await _loadOrCreateKey();

    final db = await openDatabase(
      path,
      password: key,
      version: schemaVersion,
      onConfigure: (db) async {
        // rawQuery: these PRAGMAs return a row, and execute() rejects that on Android.
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.rawQuery('PRAGMA synchronous=NORMAL');
        await db.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: (db, version) async {
        final batch = db.batch();
        for (final stmt in _schema) {
          batch.execute(stmt);
        }
        await batch.commit(noResult: true);
      },
    );

    final rows = await db.query('app_settings');
    final settings = {for (final r in rows) r['key'] as String: r['value'] as String};
    final instance = AppDatabase._(db, settings);
    await instance.purgeExpired();
    return instance;
  }

  static Future<String> _loadOrCreateKey() async {
    const storage = FlutterSecureStorage();
    var key = await storage.read(key: _keyName);
    if (key == null) {
      final r = Random.secure();
      key = List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await storage.write(key: _keyName, value: key);
    }
    return key;
  }

  static const _schema = <String>[
    '''
    CREATE TABLE app_settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )''',
    '''
    CREATE TABLE athletes (
      id         TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      dob        TEXT NOT NULL,
      gender     TEXT NOT NULL,
      school     TEXT NOT NULL DEFAULT '',
      district   TEXT NOT NULL DEFAULT '',
      state      TEXT NOT NULL DEFAULT '',
      height_cm  REAL,
      created_at INTEGER NOT NULL,
      deleted_at INTEGER
    )''',
    '''
    CREATE TABLE consents (
      id                TEXT PRIMARY KEY,
      athlete_id        TEXT NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
      is_minor          INTEGER NOT NULL,
      guardian_name     TEXT,
      guardian_relation TEXT,
      consent_form_path TEXT,
      consent_version   TEXT NOT NULL,
      purposes          TEXT NOT NULL,
      granted_at        INTEGER NOT NULL,
      withdrawn_at      INTEGER
    )''',
    '''
    CREATE TABLE test_results (
      id          TEXT PRIMARY KEY,
      athlete_id  TEXT NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
      test_id     TEXT NOT NULL,
      attempt_no  INTEGER NOT NULL,
      ai_score    REAL,
      final_score REAL NOT NULL,
      unit        TEXT NOT NULL,
      confidence  REAL NOT NULL,
      is_override INTEGER NOT NULL DEFAULT 0,
      simulated   INTEGER NOT NULL DEFAULT 0,
      metadata    TEXT NOT NULL DEFAULT '{}',
      created_at  INTEGER NOT NULL,
      synced      INTEGER NOT NULL DEFAULT 0,
      deleted_at  INTEGER
    )''',
    // Video metadata only. The .mp4 lives on disk and can be purged independently.
    '''
    CREATE TABLE videos (
      id          TEXT PRIMARY KEY,
      athlete_id  TEXT NOT NULL REFERENCES athletes(id) ON DELETE CASCADE,
      test_id     TEXT NOT NULL,
      result_id   TEXT REFERENCES test_results(id) ON DELETE SET NULL,
      file_path   TEXT NOT NULL,
      size_bytes  INTEGER NOT NULL,
      recorded_at INTEGER NOT NULL,
      lat         REAL,
      lng         REAL,
      synced      INTEGER NOT NULL DEFAULT 0,
      purged_at   INTEGER,
      deleted_at  INTEGER
    )''',
    // Manual overrides captured as labelled samples for future model retraining.
    '''
    CREATE TABLE training_labels (
      id           TEXT PRIMARY KEY,
      result_id    TEXT NOT NULL REFERENCES test_results(id) ON DELETE CASCADE,
      test_id      TEXT NOT NULL,
      ai_score     REAL,
      manual_score REAL NOT NULL,
      delta        REAL,
      reason       TEXT NOT NULL,
      features     TEXT NOT NULL DEFAULT '{}',
      created_at   INTEGER NOT NULL
    )''',
    'CREATE INDEX idx_results_athlete ON test_results(athlete_id, test_id) WHERE deleted_at IS NULL',
    'CREATE INDEX idx_videos_athlete ON videos(athlete_id)',
    'CREATE INDEX idx_consents_athlete ON consents(athlete_id)',
  ];

  // ---- Settings (cached for synchronous reads at startup) ----

  String? cachedSetting(String key) => _settings[key];

  Future<void> setSetting(String key, String value) async {
    _settings[key] = value;
    await db.insert('app_settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---- 30-day recycle bin ----

  /// Permanently removes rows soft-deleted more than 30 days ago (and their files).
  Future<int> purgeExpired({DateTime? now}) async {
    final cutoff = (now ?? DateTime.now())
        .subtract(const Duration(days: recycleBinDays))
        .millisecondsSinceEpoch;
    var purged = 0;
    await db.transaction((txn) async {
      final videos = await txn.rawQuery('''
        SELECT v.file_path FROM videos v
        LEFT JOIN athletes a ON a.id = v.athlete_id
        WHERE (v.deleted_at IS NOT NULL AND v.deleted_at < ?)
           OR (a.deleted_at IS NOT NULL AND a.deleted_at < ?)''', [cutoff, cutoff]);
      for (final v in videos) {
        await _deleteFileQuietly(v['file_path'] as String);
      }
      final consentForms = await txn.rawQuery('''
        SELECT c.consent_form_path FROM consents c
        JOIN athletes a ON a.id = c.athlete_id
        WHERE a.deleted_at IS NOT NULL AND a.deleted_at < ?''', [cutoff]);
      for (final c in consentForms) {
        final path = c['consent_form_path'] as String?;
        if (path != null) await _deleteFileQuietly(path);
      }
      purged += await txn.delete('videos', where: 'deleted_at IS NOT NULL AND deleted_at < ?', whereArgs: [cutoff]);
      purged += await txn.delete('test_results', where: 'deleted_at IS NOT NULL AND deleted_at < ?', whereArgs: [cutoff]);
      purged += await txn.delete('athletes', where: 'deleted_at IS NOT NULL AND deleted_at < ?', whereArgs: [cutoff]);
    });
    if (purged > 0) debugPrint('[DB] recycle bin purged $purged rows');
    return purged;
  }

  static Future<void> _deleteFileQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[DB] could not delete $path: $e');
    }
  }

  Future<void> close() => db.close();
}

/// Overridden in `main()` with the opened instance.
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => throw StateError('appDatabaseProvider must be overridden in main()'),
);
