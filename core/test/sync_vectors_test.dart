// Cross-language test vectors for the sync protocol. Dart writes
// test/fixtures/sync-vectors-dart.json, which Samriddhi's Rust client
// (crate brahma-sync) must read; Rust writes sync-vectors-rust.json, which
// this test reads. Copy each file to the other repo when it changes:
//   UPDATE_FIXTURES=1 flutter test test/sync_vectors_test.dart
// Every value is synthetic.
import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

const email = 'Vector.Person@Example.com';
const password = 'correct horse battery staple';
const recovery = '0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ-0123-4567-89AB-CDEF-GHJK';
const owner = 'u0000000000vector';
const device = 'd1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1';
const seq = 7;
final dek = List<int>.generate(32, (i) => i * 7 % 256);
final linkSecret = List<int>.generate(32, (i) => 255 - i);
final recipientSeed = List<int>.generate(32, (i) => (i * 13 + 5) % 256);
final requesterSeed = List<int>.generate(32, (i) => (i * 29 + 1) % 256);
const pairingId = 'abcdefghij12345';

final rows = [
  {
    't': 'bridge_money_snapshot',
    'r': {
      'id': 'artha.money',
      'hlc': '001763290000000-000002-$device',
      'deleted': 0,
      'source': 'artha',
      'snapshot': '{"v":1,"currency":"GBP"}',
      'updated': '2026-11-16T09:00:00.000Z',
    },
  },
  {
    't': 'entries',
    'r': {'id': 'e1', 'hlc': '001763290000001-000000-$device', 'deleted': 1, 'memo': 'Café £3.20 ✓'},
    'p': [
      {'id': 'p1', 'entry_id': 'e1', 'position': 0, 'amount': -320},
    ],
  },
];

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
List<int> unhex(String s) => [
  for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
];

/// HLC steps every client must take the same way: (op, argument, now) to
/// the stamp a tick returns ('' after a receive).
List<List<Object>> hlcSteps() {
  var now = 1000;
  final clock = HlcClock('abc', now: () => now);
  final out = <List<Object>>[];
  void tick(int at) {
    now = at;
    out.add(['tick', '', at, clock.tick()]);
  }

  void receive(String stamp, int at) {
    now = at;
    clock.receive(stamp);
    out.add(['receive', stamp, at, '']);
  }

  tick(1000);
  tick(1000);
  tick(999);
  receive('000000000005000-000003-zzz', 1001);
  tick(1002);
  receive('000000000005000-000009-zzz', 1003);
  receive('garbage', 1003);
  tick(6000);
  receive('000000000006000-000000-zzz', 6000);
  tick(5999);
  return out;
}

void main() {
  final dartFile = File('test/fixtures/sync-vectors-dart.json');
  final rustFile = File('test/fixtures/sync-vectors-rust.json');

  test('Dart writes vectors the Rust client must read', () async {
    final keys = await VaultCrypto.fromPassword(email, password);
    final kek = await keys.kek.extractBytes();
    final recoveryKek = await (await VaultCrypto.recoveryKek(recovery)).extractBytes();
    final link = PairingLink(Uri.parse('http://127.0.0.1:8787'), pairingId, linkSecret, scheme: 'samriddhi');
    final requester = await X25519().newKeyPairFromSeed(requesterSeed);
    final requesterKey = (await requester.extractPublicKey()).bytes;
    final recipient = await X25519().newKeyPairFromSeed(recipientSeed);
    final recipientKey = (await recipient.extractPublicKey()).bytes;
    final grant = PairingGrant(
      email: 'vector.person@example.com',
      userId: owner,
      secret: keys.authSecret,
      dataKey: dek,
    );
    final deterministic = {
      'email': email,
      'pw': password,
      'login': keys.authSecret,
      'kek': hex(kek),
      'recoveryText': recovery,
      'recoveryKek': hex(recoveryKek),
      'dek': hex(dek),
      'owner': owner,
      'device': device,
      'seq': seq,
      'aad': '${VaultCrypto.version}|$owner|$device|$seq',
      'rows': rows,
      'hlc': hlcSteps(),
      'pairing': {
        'link': '$link',
        'id': pairingId,
        'linkBytes': hex(linkSecret),
        'requesterSeed': hex(requesterSeed),
        'requesterPub': hex(requesterKey),
        'code': await PairingCrypto.code(link, requesterKey),
        'recipientSeed': hex(recipientSeed),
        'recipientPub': hex(recipientKey),
        'grant': {'email': grant.email, 'userId': grant.userId, 'login': grant.secret, 'dek': hex(dek)},
      },
      'moved': {
        'link': '${MovedLink(Uri.parse('https://sync.example.com'))}',
        'server': 'https://sync.example.com',
      },
    };
    if (Platform.environment['UPDATE_FIXTURES'] == '1' || !dartFile.existsSync()) {
      final sealed = {
        'wrappedPw': await VaultCrypto.wrapKey(dek, keys.kek, 'password'),
        'wrappedRecovery': await VaultCrypto.wrapKey(dek, SecretKey(recoveryKek), 'recovery'),
        'payload': await VaultCrypto.seal({'v': 1, 'rows': rows}, dek, deterministic['aad']! as String),
        'pairRequest': await PairingCrypto.sealRequest(
          link,
          JoinRequest(name: 'Vector phone', platform: 'android', publicKey: requesterKey),
        ),
        'pairGrant': await PairingCrypto.sealGrant(link, recipientKey, grant),
      };
      dartFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({...deterministic, ...sealed})}\n',
      );
    }
    // The file on disk still matches this code, and its ciphertexts open.
    final saved = jsonDecode(dartFile.readAsStringSync()) as Map<String, Object?>;
    for (final MapEntry(:key, :value) in deterministic.entries) {
      expect(jsonEncode(saved[key]), jsonEncode(value), reason: key);
    }
    expect(await VaultCrypto.unwrapKey(saved['wrappedPw']! as String, keys.kek, 'password'), dek);
    expect(await VaultCrypto.open(saved['payload']! as String, dek, deterministic['aad']! as String), {
      'v': 1,
      'rows': rows,
    });
  });

  test('Dart reads the vectors the Rust client wrote', () async {
    expect(
      rustFile.existsSync(),
      isTrue,
      reason: 'run the brahma-sync tests in Samriddhi and copy sync-vectors-rust.json here',
    );
    final v = jsonDecode(rustFile.readAsStringSync()) as Map<String, Object?>;
    // Same inputs, same keys.
    final keys = await VaultCrypto.fromPassword(v['email']! as String, v['pw']! as String);
    expect(v['login'], keys.authSecret);
    expect(v['kek'], hex(await keys.kek.extractBytes()));
    final dataKey = unhex(v['dek']! as String);
    expect(await VaultCrypto.unwrapKey(v['wrappedPw']! as String, keys.kek, 'password'), dataKey);
    // A recovery key Rust made, in the same Crockford form.
    final rk = await VaultCrypto.recoveryKek(v['recoveryText']! as String);
    expect(hex(await rk.extractBytes()), v['recoveryKek']);
    expect(await VaultCrypto.unwrapKey(v['wrappedRecovery']! as String, rk, 'recovery'), dataKey);
    // A change Rust sealed opens here, row for row; a moved one does not.
    final aad = v['aad']! as String;
    expect(await VaultCrypto.open(v['payload']! as String, dataKey, aad), {'v': 1, 'rows': v['rows']});
    await expectLater(
      VaultCrypto.open(v['payload']! as String, dataKey, '${aad}9'),
      throwsA(isA<CryptoException>()),
    );
    // The HLC steps Rust took match this clock's.
    expect(jsonEncode(v['hlc']), jsonEncode(hlcSteps()));
    // Pairing: Rust's join request opens with the link, the codes agree, and
    // Rust's grant (sealed to a key whose seed both know) opens here.
    final p = v['pairing']! as Map<String, Object?>;
    final link = BrahmaLink.parse(p['link']! as String) as PairingLink;
    expect(link.id, p['id']);
    expect(hex(link.secret), p['linkBytes']);
    final request = await PairingCrypto.openRequest(link, v['pairRequest']! as String);
    expect(hex(request.publicKey), p['requesterPub']);
    expect(request.name, 'Vector laptop');
    expect(await PairingCrypto.code(link, request.publicKey), p['code']);
    final recipient = await X25519().newKeyPairFromSeed(unhex(p['recipientSeed']! as String));
    final grant = await PairingCrypto.openGrant(JoinTicket(link, recipient, ''), v['pairGrant']! as String);
    final g = p['grant']! as Map<String, Object?>;
    expect(
      [grant.email, grant.userId, grant.secret, hex(grant.dataKey)],
      [g['email'], g['userId'], g['login'], g['dek']],
    );
    expect(BrahmaLink.parse((v['moved']! as Map)['link']! as String), isA<MovedLink>());
  });
}
