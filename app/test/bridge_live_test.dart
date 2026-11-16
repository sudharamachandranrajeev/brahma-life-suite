// Udyoga and Vidya, each with its own database as the suite holds them,
// share one account on the real home server (../server/src/home.ts, Node
// 24+) on loopback: a plan sent from Udyoga is offered in Vidya, and what is
// finished in Vidya comes back to Udyoga, through sync alone.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart' hide Release, UpdateException, checksumsName, updaterProvider;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:udyoga/db/database.dart' as u;
import 'package:udyoga/domain/book.dart';
import 'package:udyoga/domain/vidya_link.dart';
import 'package:vidya/db/database.dart' as v;
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/udyoga_link.dart';

const _app = AppIdentity(id: 'brahma', name: 'Brahma', androidPackage: 'dev.brahma.app');

void main() {
  late Directory dir;
  late Process server;
  late String url, setupCode;
  final home = '${Directory.current.parent.path}/server/src/home.ts';
  final node = Process.runSync('node', ['--version']);
  final major = int.tryParse(RegExp(r'v(\d+)').firstMatch('${node.stdout}')?.group(1) ?? '') ?? 0;
  final skip = node.exitCode != 0 || major < 24 ? 'Needs Node 24 or newer' : null;

  setUpAll(() async {
    HttpOverrides.global = null;
    if (skip != null) return;
    dir = await Directory.systemTemp.createTemp('brahma-bridge-test-');
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final env = {'BRAHMA_SERVER_HOME': dir.path};
    expect((await Process.run('node', [home, 'init', '$port'], environment: env)).exitCode, 0);
    setupCode = RegExp(
      r'^SETUP_CODE=(.+)$',
      multiLine: true,
    ).firstMatch(await File('${dir.path}/server.env').readAsString())!.group(1)!;
    server = await Process.start('node', [home, 'serve'], environment: env);
    final ready = Completer<void>();
    server.stdout.transform(utf8.decoder).listen((t) {
      if (t.contains('listening') && !ready.isCompleted) ready.complete();
    });
    server.stderr.transform(utf8.decoder).listen(stderr.write);
    await ready.future.timeout(const Duration(seconds: 20));
    url = 'http://127.0.0.1:$port';
  });

  tearDownAll(() async {
    if (skip != null) return;
    server.kill();
    await server.exitCode;
    await dir.delete(recursive: true);
  });

  test('a plan goes from Udyoga to Vidya and progress comes back, through sync alone', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final account = AccountService(
      KeyVault(MemorySecretStore(), _app),
      deviceId: 'd' * 32,
      platform: 'linux',
    );
    await account.signUp(
      server: url,
      email: 'me@home.test',
      password: 'correct horse battery',
      invite: setupCode,
    );
    final udb = u.AppDatabase(NativeDatabase.memory()), vdb = v.AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await udb.close();
      await vdb.close();
    });
    final career = CareerBook(await Store.open(udb));
    final learning = LearningBook(await Store.open(vdb));
    Future<void> sync(Store s) async => (await account.engine(s))!.run();

    await career.sendToVidya(now: '2026-11-16T09:00:00Z');
    await sync(career.store);
    await sync(learning.store);
    final offer = (await learning.offeredPlans()).single;
    expect(offer.plan.title, startsWith('Interview ready'));
    await learning.addOfferedPlan(offer, today: '2026-11-16', now: '2026-11-16T09:05:00Z');
    final id = await learning.addCourse('Care Certificate', today: '2026-11-16', kind: 'certification');
    final course = await (vdb.select(vdb.learnCourses)..where((c) => c.id.equals(id))).getSingle();
    await learning.setCourseStatus(course, 'done', today: '2026-11-16');
    await learning.addSkill('SystmOne', today: '2026-11-16', category: 'Digital', level: 4);
    await learning.reportToUdyoga(now: '2026-11-16T10:00:00Z');
    await sync(learning.store);
    await sync(career.store);

    final link = await career.vidyaBridge();
    expect(link.added, isTrue);
    expect(link.done.learning.map((l) => l.title), ['Care Certificate']);
    expect(link.done.skills, ['SystmOne']);
    // Neither app took the other's own tables.
    expect(await udb.customSelect("SELECT name FROM sqlite_master WHERE name LIKE 'learn_%'").get(), isEmpty);
  }, skip: skip);
}
