import 'dart:convert';

import 'package:drift/drift.dart';

// Tables two Brahma apps share, so one learns what the other knows as soon
// as both sync with the same account. Each app declares the ones it uses,
// with exactly these class names, and lists their SQL names in its
// `syncedTables`:
//
//   @DataClassName('StudyPlan')
//   class BridgeStudyPlans extends Table with SyncedRow, StudyPlanColumns {}
//   @DataClassName('StudyProgressRow')
//   class BridgeStudyProgress extends Table with SyncedRow, StudyProgressColumns {}
//
// One app writes each table; the other only reads it. A row is the whole
// message, as JSON, so an older app that does not know a field ignores it,
// and an app without the table ignores the rows. With no sync server the
// apps still swap the same content as files.

/// `bridge_study_plans`: a study plan one app (Udyoga) sends to the learning
/// app (Vidya). Re-sending the same plan keeps its id and replaces it.
mixin StudyPlanColumns on Table {
  /// The app that wrote it, as its identity id (`udyoga`).
  TextColumn get source => text()();

  /// The plan, as "vidya-curriculum" JSON (version 1).
  TextColumn get plan => text()();

  /// When it was last sent (UTC, ISO 8601). Tells the reader it changed.
  TextColumn get updated => text()();
}

/// `bridge_study_progress`: what the learning app reports back for a plan.
/// Its id is the plan's id.
mixin StudyProgressColumns on Table {
  /// The `updated` of the plan version added to the learning app; empty
  /// until it is added.
  TextColumn get planUpdated => text().withDefault(const Constant(''))();

  /// [StudyProgress] as JSON.
  TextColumn get progress => text().withDefault(const Constant('{}'))();

  /// When the progress last changed (UTC, ISO 8601).
  TextColumn get updated => text()();
}

/// One finished course, certificate or degree.
typedef FinishedLearning = ({String title, String kind, String provider, String finished});

/// A skill and how well it is held, 0 (not rated) to 5 (expert).
typedef RatedSkill = ({String name, String category, int level});

/// What the learner finished and can do, the content of a progress row.
class StudyProgress {
  const StudyProgress({this.learning = const [], this.skills = const []});

  final List<FinishedLearning> learning;
  final List<RatedSkill> skills;

  /// Reads what any version wrote; a damaged or missing field reads as empty.
  factory StudyProgress.parse(String text) {
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return const StudyProgress();
    }
    if (json is! Map) return const StudyProgress();
    String s(Object? v) => v is String ? v : '';
    List<Map<Object?, Object?>> maps(Object? v) => [if (v is List) ...v.whereType<Map<Object?, Object?>>()];
    return StudyProgress(
      learning: [
        for (final m in maps(json['learning']))
          if (s(m['title']).isNotEmpty)
            (
              title: s(m['title']),
              kind: s(m['kind']),
              provider: s(m['provider']),
              finished: s(m['finished']),
            ),
      ],
      skills: [
        for (final m in maps(json['skills']))
          if (s(m['name']).isNotEmpty)
            (
              name: s(m['name']),
              category: s(m['category']),
              level: m['level'] is int ? m['level']! as int : 0,
            ),
      ],
    );
  }

  /// Stable text for the row: the same progress always gives the same text,
  /// so the writer can skip a write that changes nothing.
  String encode() => jsonEncode({
    'learning': [
      for (final l in learning)
        {'title': l.title, 'kind': l.kind, 'provider': l.provider, 'finished': l.finished},
    ],
    'skills': [
      for (final k in skills) {'name': k.name, 'category': k.category, 'level': k.level},
    ],
  });
}
