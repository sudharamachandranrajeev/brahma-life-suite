import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic figures only. The fixtures are shared with Artha and Samriddhi
// (Rust): copy them over when they change (`UPDATE_FIXTURES=1 flutter test`).
const money = MoneySnapshot(
  currency: 'GBP',
  month: '2026-11',
  asOf: '2026-11-16',
  income: 231245,
  spend: 162310,
  spendByCategory: [
    (category: 'Rent', amount: 85000),
    (category: 'Groceries', amount: 31277),
    (category: 'Transport', amount: 12033),
  ],
  fixedCosts: 98599,
  liquidCash: 412350,
  debts: [(name: 'Credit card', balance: 64520)],
  forecast: (days: 90, start: 412350, end: 398100, low: 301777, lowDate: '2026-12-29'),
  freshness: [
    (account: 'Current account', lastStatement: '2026-10-31'),
    (account: 'Savings', lastStatement: ''),
  ],
);

const wealth = WealthSnapshot(
  currency: 'GBP',
  asOf: '2026-11-16',
  holdingsCount: 4,
  holdingsTotal: 1825099,
  byClass: [(assetClass: 'equity', value: 1300000), (assetClass: 'cash', value: 525099)],
  netWorth: [(month: '2026-09', value: 1650000), (month: '2026-10', value: 1712345)],
  exposure: [
    (kind: 'currency', key: 'GBP', value: 1200000),
    (kind: 'currency', key: 'USD', value: 625099),
    (kind: 'country', key: 'GB', value: 900000),
  ],
);

void fixture(String name, String text) {
  final file = File('test/fixtures/$name');
  if (Platform.environment['UPDATE_FIXTURES'] == '1' || !file.existsSync()) {
    file.writeAsStringSync('$text\n');
  }
  expect(file.readAsStringSync().trim(), text, reason: 'fixture $name is out of date');
}

void main() {
  test('a money snapshot survives the round trip, exactly', () {
    final again = MoneySnapshot.parse(money.encode());
    expect(again.encode(), money.encode());
    expect(again.version, MoneySnapshot.current);
    expect(again.spendByCategory, money.spendByCategory);
    expect(again.forecast, money.forecast);
    expect(again.debtTotal, 64520);
    fixture('money-snapshot.json', money.encode());
  });

  test('a wealth snapshot survives the round trip, exactly', () {
    final again = WealthSnapshot.parse(wealth.encode());
    expect(again.encode(), wealth.encode());
    expect(again.byClass, wealth.byClass);
    expect(again.latestNetWorth, (month: '2026-10', value: 1712345));
    fixture('wealth-snapshot.json', wealth.encode());
  });

  test('the shared fixtures read back to the same text', () {
    for (final (name, parse) in [
      ('money-snapshot.json', (String t) => MoneySnapshot.parse(t).encode()),
      ('wealth-snapshot.json', (String t) => WealthSnapshot.parse(t).encode()),
    ]) {
      final text = File('test/fixtures/$name').readAsStringSync().trim();
      expect(parse(text), text, reason: name);
    }
  });

  test('damaged or newer snapshots read as far as they can, never throw', () {
    for (final text in ['', 'not json', '[]', '{"debts": 3}', '{"spendByCategory": [1, "x", {}]}']) {
      final m = MoneySnapshot.parse(text);
      expect([...m.spendByCategory, ...m.debts, ...m.freshness], isEmpty, reason: text);
      expect(m.forecast, isNull);
      final w = WealthSnapshot.parse(text);
      expect([...w.byClass, ...w.netWorth, ...w.exposure], isEmpty, reason: text);
    }
    final newer = MoneySnapshot.parse(
      '{"v":2,"currency":"GBP","income":10.5,"spend":7,"debts":[{"name":"Loan","balance":"9"}],"pots":[]}',
    );
    expect(newer.version, 2);
    expect(newer.income, 0, reason: 'a non-whole amount is not trusted');
    expect(newer.spend, 7);
    expect(newer.debts.single, (name: 'Loan', balance: 0));
    expect(const MoneySnapshot().isEmpty, isTrue);
    expect(WealthSnapshot.parse('{"v":1,"currency":"GBP","holdings":"x"}').holdingsTotal, 0);
  });
}
