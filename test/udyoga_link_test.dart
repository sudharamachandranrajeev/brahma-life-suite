import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/udyoga_link.dart';

import 'support.dart';

const today = '2026-11-16';

void main() {
  late LearningBook book;
  late AppDatabase db;
  setUp(() async {
    db = memoryDatabase();
    book = LearningBook(await Store.open(db));
  });
  tearDown(() => db.close());

  // As a plan arrives from Udyoga through sync (Udyoga's fixture).
  Future<void> receive(String updated) => db
      .into(db.bridgeStudyPlans)
      .insertOnConflictUpdate(
        BridgeStudyPlansCompanion.insert(
          id: 'udyoga.study-plan',
          source: 'udyoga',
          plan: File('test/fixtures/udyoga-plan.json').readAsStringSync(),
          updated: updated,
        ),
      );

  Future<StudyProgressRow?> progress() =>
      (db.select(db.bridgeStudyProgress)..where((p) => p.id.equals('udyoga.study-plan'))).getSingleOrNull();

  test('a plan from Udyoga is offered until added, and again when it changes', () async {
    expect(await book.offeredPlans(), isEmpty);
    await book.reportToUdyoga(now: '$today T1');
    expect(await progress(), isNull, reason: 'nothing is reported before a plan arrives');

    await receive('2026-11-16T09:00:00Z');
    final offers = await book.offeredPlans();
    expect(offers.single.plan.title, startsWith('Interview ready'));
    await book.reportToUdyoga(now: '$today T2');
    expect(await progress(), isNull, reason: 'nor before it is added');

    final r = await book.addOfferedPlan(offers.single, today: today, now: '$today T3');
    expect(r.courses, offers.single.plan.courses.length);
    expect(await book.offeredPlans(), isEmpty);
    expect((await progress())!.planUpdated, '2026-11-16T09:00:00Z');

    // Re-sent: offered again; adding updates the same program.
    await receive('2026-11-17T09:00:00Z');
    final again = await book.offeredPlans();
    expect(again, hasLength(1));
    final before = (await (db.select(db.learnPrograms)).get()).length;
    await book.addOfferedPlan(again.single, today: today, now: '$today T4');
    expect((await (db.select(db.learnPrograms)).get()).length, before);
    expect((await progress())!.planUpdated, '2026-11-17T09:00:00Z');
  });

  test('progress goes back only when it changes, and the fixture Udyoga reads is current', () async {
    await receive('2026-11-16T09:00:00Z');
    await book.addOfferedPlan((await book.offeredPlans()).single, today: today, now: 'T1');
    final first = await progress();

    await book.reportToUdyoga(now: 'T2');
    expect((await progress())!.hlc, first!.hlc, reason: 'no change, no write');

    final id = await book.addCourse(
      'Care Certificate',
      today: today,
      kind: 'certification',
      provider: 'Skills for Health',
    );
    final course = await (db.select(db.learnCourses)..where((c) => c.id.equals(id))).getSingle();
    await book.setCourseStatus(course, 'done', today: '2026-11-03');
    await book.addSkill('SystmOne', today: today, category: 'Digital', level: 3);
    await book.addSkill('Excel', today: today, category: 'Digital', level: 2);
    await book.reportToUdyoga(now: 'T3');
    final row = (await progress())!;
    expect(row.hlc, isNot(first.hlc));
    expect(row.planUpdated, '2026-11-16T09:00:00Z', reason: 'progress keeps the added plan version');
    final p = StudyProgress.parse(row.progress);
    expect(p.learning.map((l) => (l.title, l.kind, l.finished)), [
      ('Care Certificate', 'certification', '2026-11-03'),
    ]);
    expect(p.skills.map((k) => (k.name, k.level)), containsAll([('SystmOne', 3), ('Excel', 2)]));

    // Udyoga's tests read this file, so a change in the format shows there.
    final fixture = File('test/fixtures/vidya-progress.json');
    final text = row.progress;
    if (!fixture.existsSync() || Platform.environment['UPDATE_FIXTURES'] == '1') {
      await fixture.writeAsString('$text\n');
    }
    expect(await fixture.readAsString(), '$text\n');
  });

  test('a plan that cannot be read is left out, not fatal', () async {
    await db
        .into(db.bridgeStudyPlans)
        .insert(BridgeStudyPlansCompanion.insert(id: 'x', source: 'udyoga', plan: 'not json', updated: 'T'));
    expect(await book.offeredPlans(), isEmpty);
  });
}
