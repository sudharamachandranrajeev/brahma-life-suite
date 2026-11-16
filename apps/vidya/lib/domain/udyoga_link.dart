/// The live link with Udyoga, the career app, through sync: a study plan it
/// sends is offered here; what is finished here goes back. Both apps must
/// sync with the same account. Without sync the plan comes as a file
/// (Import a study plan) and progress goes back as the portfolio.
library;

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'curriculum.dart';

/// A plan another app sent that this one has not added in its latest form.
typedef OfferedPlan = ({StudyPlan row, CurriculumPlan plan});

extension UdyogaLink on LearningBook {
  /// Plans sent and not yet added (or changed since). A plan that cannot be
  /// read is left out, not fatal: it may come from a newer Udyoga.
  Future<List<OfferedPlan>> offeredPlans() async {
    final plans = await (db.select(db.bridgeStudyPlans)..where((p) => p.deleted.not())).get();
    final added = {
      for (final p in await (db.select(db.bridgeStudyProgress)..where((p) => p.deleted.not())).get())
        p.id: p.planUpdated,
    };
    final out = <OfferedPlan>[];
    for (final row in plans) {
      if (added[row.id] == row.updated) continue;
      try {
        out.add((row: row, plan: parseCurriculum(row.plan)));
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  /// Adds [offer] as the file import would (merging by title, so adding a
  /// re-sent plan updates the same program), and tells the sender it is in.
  Future<CurriculumImport> addOfferedPlan(OfferedPlan offer, {required String today, required String now}) =>
      db.transaction(() async {
        final r = await importCurriculum(offer.plan, today: today);
        await _report(offer.row.id, planUpdated: offer.row.updated, now: now, force: true);
        return r;
      });

  /// What was finished and the rated skills, as the portfolio lists them.
  Future<StudyProgress> studyProgress() async {
    final courses =
        await (db.select(db.learnCourses)
              ..where((c) => c.deleted.not() & c.status.equals('done'))
              ..orderBy([(c) => OrderingTerm.asc(c.title)]))
            .get();
    final skills =
        await (db.select(db.learnSkills)
              ..where((k) => k.deleted.not() & k.level.isBiggerThanValue(0))
              ..orderBy([(k) => OrderingTerm.asc(k.name)]))
            .get();
    return StudyProgress(
      learning: [
        for (final c in courses)
          (title: c.title, kind: c.kind, provider: c.provider, finished: c.finished ?? ''),
      ],
      skills: [for (final k in skills) (name: k.name, category: k.category, level: k.level)],
    );
  }

  /// Updates the progress for every plan received, only when it changed,
  /// so ordinary study does not fill the sync log. Nothing happens until a
  /// plan has come from Udyoga.
  Future<void> reportToUdyoga({required String now}) async {
    final plans = await (db.select(db.bridgeStudyPlans)..where((p) => p.deleted.not())).get();
    for (final p in plans) {
      await _report(p.id, now: now);
    }
  }

  Future<void> _report(String planId, {String? planUpdated, required String now, bool force = false}) async {
    final old = await (db.select(
      db.bridgeStudyProgress,
    )..where((p) => p.id.equals(planId))).getSingleOrNull();
    final progress = (await studyProgress()).encode();
    final mark = planUpdated ?? old?.planUpdated ?? '';
    if (!force && old != null && !old.deleted && old.progress == progress && old.planUpdated == mark) return;
    if (!force && old == null) return; // Not added yet: nothing to report on.
    await save(
      db.bridgeStudyProgress,
      BridgeStudyProgressCompanion.insert(
        id: planId,
        planUpdated: Value(mark),
        progress: Value(progress),
        updated: now,
      ),
      planId,
    );
  }
}
