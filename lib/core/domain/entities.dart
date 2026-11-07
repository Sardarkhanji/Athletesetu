import 'dart:convert';
import 'dart:math';

import 'sai_test.dart';

/// Collision-resistant local id (no network, no uuid package).
String newId([String prefix = '']) {
  final r = Random.secure();
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join();
  return '$prefix$ts$rand';
}

enum AppMode { individual, coachAthleteWise, coachStationWise }

class Athlete {
  const Athlete({
    required this.id,
    required this.name,
    required this.dob,
    required this.gender,
    required this.createdAt,
    this.school = '',
    this.district = '',
    this.state = '',
    this.heightCm,
    this.deletedAt,
  });

  final String id;
  final String name;
  final DateTime dob;
  final String gender; // 'M' | 'F' | 'O'
  final String school;
  final String district;
  final String state;

  /// Last confirmed height, used for BMI when weight is measured.
  final double? heightCm;
  final DateTime createdAt;
  final DateTime? deletedAt;

  int get age => ageOn(DateTime.now());

  int ageOn(DateTime day) {
    var a = day.year - dob.year;
    if (day.month < dob.month || (day.month == dob.month && day.day < dob.day)) a--;
    return a;
  }

  bool get isMinor => age < 18;

  /// Age used for age-group test rules (ruling C30: computed at registration).
  int get ageAtRegistration => ageOn(createdAt);

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'dob': dob.toIso8601String(),
        'gender': gender,
        'school': school,
        'district': district,
        'state': state,
        'height_cm': heightCm,
        'created_at': createdAt.millisecondsSinceEpoch,
        'deleted_at': deletedAt?.millisecondsSinceEpoch,
      };

  factory Athlete.fromRow(Map<String, Object?> r) => Athlete(
        id: r['id'] as String,
        name: r['name'] as String,
        dob: DateTime.parse(r['dob'] as String),
        gender: r['gender'] as String,
        school: (r['school'] as String?) ?? '',
        district: (r['district'] as String?) ?? '',
        state: (r['state'] as String?) ?? '',
        heightCm: (r['height_cm'] as num?)?.toDouble(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        deletedAt: r['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['deleted_at'] as int),
      );

  Athlete copyWith({double? heightCm}) => Athlete(
        id: id,
        name: name,
        dob: dob,
        gender: gender,
        school: school,
        district: district,
        state: state,
        heightCm: heightCm ?? this.heightCm,
        createdAt: createdAt,
        deletedAt: deletedAt,
      );
}

/// DPDP Act 2023 consent. Minors need a guardian and a photo of the signed form.
class ConsentRecord {
  const ConsentRecord({
    required this.id,
    required this.athleteId,
    required this.isMinor,
    required this.consentVersion,
    required this.grantedAt,
    required this.purposes,
    this.guardianName,
    this.guardianRelation,
    this.consentFormPath,
    this.withdrawnAt,
  });

  final String id;
  final String athleteId;
  final bool isMinor;
  final String? guardianName;
  final String? guardianRelation;
  final String? consentFormPath;
  final String consentVersion;
  final List<String> purposes;
  final DateTime grantedAt;
  final DateTime? withdrawnAt;

  bool get isValid =>
      withdrawnAt == null &&
      (!isMinor ||
          ((guardianName?.trim().isNotEmpty ?? false) &&
              (guardianRelation?.trim().isNotEmpty ?? false) &&
              (consentFormPath?.isNotEmpty ?? false)));

  Map<String, Object?> toRow() => {
        'id': id,
        'athlete_id': athleteId,
        'is_minor': isMinor ? 1 : 0,
        'guardian_name': guardianName,
        'guardian_relation': guardianRelation,
        'consent_form_path': consentFormPath,
        'consent_version': consentVersion,
        'purposes': jsonEncode(purposes),
        'granted_at': grantedAt.millisecondsSinceEpoch,
        'withdrawn_at': withdrawnAt?.millisecondsSinceEpoch,
      };

  factory ConsentRecord.fromRow(Map<String, Object?> r) => ConsentRecord(
        id: r['id'] as String,
        athleteId: r['athlete_id'] as String,
        isMinor: (r['is_minor'] as int) == 1,
        guardianName: r['guardian_name'] as String?,
        guardianRelation: r['guardian_relation'] as String?,
        consentFormPath: r['consent_form_path'] as String?,
        consentVersion: r['consent_version'] as String,
        purposes: (jsonDecode(r['purposes'] as String) as List).cast<String>(),
        grantedAt: DateTime.fromMillisecondsSinceEpoch(r['granted_at'] as int),
        withdrawnAt: r['withdrawn_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['withdrawn_at'] as int),
      );
}

class TestResult {
  const TestResult({
    required this.id,
    required this.athleteId,
    required this.test,
    required this.attemptNo,
    required this.finalScore,
    required this.confidence,
    required this.isOverride,
    required this.simulated,
    required this.createdAt,
    this.aiScore,
    this.metadata = const {},
    this.synced = false,
    this.deletedAt,
  });

  final String id;
  final String athleteId;
  final SaiTest test;
  final int attemptNo;
  final double? aiScore;
  final double finalScore;

  /// 0–100.
  final double confidence;
  final bool isOverride;
  final bool simulated;
  final Map<String, Object?> metadata;
  final DateTime createdAt;
  final bool synced;
  final DateTime? deletedAt;

  Map<String, Object?> toRow() => {
        'id': id,
        'athlete_id': athleteId,
        'test_id': test.id,
        'attempt_no': attemptNo,
        'ai_score': aiScore,
        'final_score': finalScore,
        'unit': test.unit,
        'confidence': confidence,
        'is_override': isOverride ? 1 : 0,
        'simulated': simulated ? 1 : 0,
        'metadata': jsonEncode(metadata),
        'created_at': createdAt.millisecondsSinceEpoch,
        'synced': synced ? 1 : 0,
        'deleted_at': deletedAt?.millisecondsSinceEpoch,
      };

  factory TestResult.fromRow(Map<String, Object?> r) => TestResult(
        id: r['id'] as String,
        athleteId: r['athlete_id'] as String,
        test: SaiTest.fromId(r['test_id'] as String),
        attemptNo: r['attempt_no'] as int,
        aiScore: (r['ai_score'] as num?)?.toDouble(),
        finalScore: (r['final_score'] as num).toDouble(),
        confidence: (r['confidence'] as num).toDouble(),
        isOverride: (r['is_override'] as int) == 1,
        simulated: (r['simulated'] as int) == 1,
        metadata: (jsonDecode(r['metadata'] as String) as Map).cast<String, Object?>(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        synced: (r['synced'] as int) == 1,
        deletedAt: r['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['deleted_at'] as int),
      );
}

/// Video files live on disk; only their metadata is in the encrypted DB.
class VideoRecord {
  const VideoRecord({
    required this.id,
    required this.athleteId,
    required this.test,
    required this.filePath,
    required this.sizeBytes,
    required this.recordedAt,
    this.resultId,
    this.lat,
    this.lng,
    this.synced = false,
    this.purgedAt,
    this.deletedAt,
  });

  final String id;
  final String athleteId;
  final SaiTest test;
  final String? resultId;
  final String filePath;
  final int sizeBytes;
  final DateTime recordedAt;
  final double? lat;
  final double? lng;
  final bool synced;
  final DateTime? purgedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toRow() => {
        'id': id,
        'athlete_id': athleteId,
        'test_id': test.id,
        'result_id': resultId,
        'file_path': filePath,
        'size_bytes': sizeBytes,
        'recorded_at': recordedAt.millisecondsSinceEpoch,
        'lat': lat,
        'lng': lng,
        'synced': synced ? 1 : 0,
        'purged_at': purgedAt?.millisecondsSinceEpoch,
        'deleted_at': deletedAt?.millisecondsSinceEpoch,
      };

  factory VideoRecord.fromRow(Map<String, Object?> r) => VideoRecord(
        id: r['id'] as String,
        athleteId: r['athlete_id'] as String,
        test: SaiTest.fromId(r['test_id'] as String),
        resultId: r['result_id'] as String?,
        filePath: r['file_path'] as String,
        sizeBytes: r['size_bytes'] as int,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(r['recorded_at'] as int),
        lat: (r['lat'] as num?)?.toDouble(),
        lng: (r['lng'] as num?)?.toDouble(),
        synced: (r['synced'] as int) == 1,
        purgedAt: r['purged_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['purged_at'] as int),
        deletedAt: r['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['deleted_at'] as int),
      );
}

/// A manual override, logged as a labelled sample for future model training.
class TrainingLabel {
  const TrainingLabel({
    required this.id,
    required this.resultId,
    required this.test,
    required this.aiScore,
    required this.manualScore,
    required this.reason,
    required this.createdAt,
    this.features = const {},
  });

  final String id;
  final String resultId;
  final SaiTest test;
  final double? aiScore;
  final double manualScore;
  final String reason;
  final Map<String, Object?> features;
  final DateTime createdAt;

  double? get delta => aiScore == null ? null : manualScore - aiScore!;

  Map<String, Object?> toRow() => {
        'id': id,
        'result_id': resultId,
        'test_id': test.id,
        'ai_score': aiScore,
        'manual_score': manualScore,
        'delta': delta,
        'reason': reason,
        'features': jsonEncode(features),
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}
