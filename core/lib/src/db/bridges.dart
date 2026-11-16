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

// ---- money and wealth (Artha and Samriddhi) ----
//
//   @DataClassName('MoneySnapshotRow')
//   class BridgeMoneySnapshot extends Table with SyncedRow, MoneySnapshotColumns {}
//   @DataClassName('WealthSnapshotRow')
//   class BridgeWealthSnapshot extends Table with SyncedRow, WealthSnapshotColumns {}
//
// Artha writes `bridge_money_snapshot` (row id [MoneySnapshot.rowId]);
// Samriddhi writes `bridge_wealth_snapshot` (row id [WealthSnapshot.rowId]).
// Each reads the other's. Amounts are exact: whole minor units (pence) of
// the snapshot's currency. Like every synced row they travel end-to-end
// encrypted, so the server never sees them.

/// `bridge_money_snapshot`: money in and out, as the ledger app sees it.
mixin MoneySnapshotColumns on Table {
  /// The app that wrote it, as its identity id (`artha`).
  TextColumn get source => text()();

  /// [MoneySnapshot] as JSON.
  TextColumn get snapshot => text().withDefault(const Constant('{}'))();

  /// When it last changed (UTC, ISO 8601).
  TextColumn get updated => text()();
}

/// `bridge_wealth_snapshot`: holdings and net worth, as the wealth app sees it.
mixin WealthSnapshotColumns on Table {
  /// The app that wrote it, as its identity id (`samriddhi`).
  TextColumn get source => text()();

  /// [WealthSnapshot] as JSON.
  TextColumn get snapshot => text().withDefault(const Constant('{}'))();

  /// When it last changed (UTC, ISO 8601).
  TextColumn get updated => text()();
}

/// Spend in one category over the snapshot's month.
typedef CategorySpend = ({String category, int amount});

/// Money owed on one account (a positive balance is owed).
typedef DebtBalance = ({String name, int balance});

/// The cash forecast in short: the balance now, at the end and at its lowest.
typedef CashForecastSummary = ({int days, int start, int end, int low, String lowDate});

/// When an account's last statement (or import) ended; empty when never.
typedef AccountFreshness = ({String account, String lastStatement});

/// Value held in one asset class (`equity`, `bonds`, `property`, `gold`, `cash`).
typedef ClassValue = ({String assetClass, int value});

/// Net worth at the end of one month (`2026-10`).
typedef MonthValue = ({String month, int value});

/// Value exposed to one currency, country or asset class ([kind] says which).
typedef Exposure = ({String kind, String key, int value});

/// What the ledger app shares: one month of money in and out, cash, debts,
/// the 90-day forecast and how fresh each account's figures are.
class MoneySnapshot {
  const MoneySnapshot({
    this.version = current,
    this.currency = '',
    this.month = '',
    this.asOf = '',
    this.income = 0,
    this.spend = 0,
    this.spendByCategory = const [],
    this.fixedCosts = 0,
    this.liquidCash = 0,
    this.debts = const [],
    this.forecast,
    this.freshness = const [],
  });

  /// The version this code writes. Readers accept any: newer fields are
  /// ignored, missing ones read as empty.
  static const current = 1;

  /// The one row Artha keeps up to date.
  static const rowId = 'artha.money';

  final int version;

  /// ISO 4217 code every amount is in (`GBP`).
  final String currency;

  /// The month the flows cover (`2026-11`), and the day they run to.
  final String month, asOf;

  /// Money in and out over [month], in minor units.
  final int income, spend;
  final List<CategorySpend> spendByCategory;

  /// Regular bills and subscriptions per month.
  final int fixedCosts;

  /// Cash that can be spent today (current and savings accounts).
  final int liquidCash;
  final List<DebtBalance> debts;
  final CashForecastSummary? forecast;
  final List<AccountFreshness> freshness;

  bool get isEmpty => currency.isEmpty;

  int get debtTotal => debts.fold(0, (a, d) => a + d.balance);

  /// Reads what any version wrote; a damaged or missing field reads as empty.
  factory MoneySnapshot.parse(String text) {
    final json = _object(text);
    if (json == null) return const MoneySnapshot(version: 0);
    final f = json['forecast'];
    return MoneySnapshot(
      version: _int(json['v']),
      currency: _str(json['currency']),
      month: _str(json['month']),
      asOf: _str(json['asOf']),
      income: _int(json['income']),
      spend: _int(json['spend']),
      spendByCategory: [
        for (final m in _maps(json['spendByCategory']))
          if (_str(m['category']).isNotEmpty) (category: _str(m['category']), amount: _int(m['amount'])),
      ],
      fixedCosts: _int(json['fixedCosts']),
      liquidCash: _int(json['liquidCash']),
      debts: [
        for (final m in _maps(json['debts']))
          if (_str(m['name']).isNotEmpty) (name: _str(m['name']), balance: _int(m['balance'])),
      ],
      forecast: f is Map
          ? (
              days: _int(f['days']),
              start: _int(f['start']),
              end: _int(f['end']),
              low: _int(f['low']),
              lowDate: _str(f['lowDate']),
            )
          : null,
      freshness: [
        for (final m in _maps(json['freshness']))
          if (_str(m['account']).isNotEmpty)
            (account: _str(m['account']), lastStatement: _str(m['lastStatement'])),
      ],
    );
  }

  /// Stable text: the same snapshot always gives the same text, so the
  /// writer can skip a write that changes nothing.
  String encode() => jsonEncode({
    'v': current,
    'currency': currency,
    'month': month,
    'asOf': asOf,
    'income': income,
    'spend': spend,
    'spendByCategory': [
      for (final c in spendByCategory) {'category': c.category, 'amount': c.amount},
    ],
    'fixedCosts': fixedCosts,
    'liquidCash': liquidCash,
    'debts': [
      for (final d in debts) {'name': d.name, 'balance': d.balance},
    ],
    'forecast': forecast == null
        ? null
        : {
            'days': forecast!.days,
            'start': forecast!.start,
            'end': forecast!.end,
            'low': forecast!.low,
            'lowDate': forecast!.lowDate,
          },
    'freshness': [
      for (final a in freshness) {'account': a.account, 'lastStatement': a.lastStatement},
    ],
  });
}

/// What the wealth app shares: holdings in short, net worth by month and
/// exposure totals.
class WealthSnapshot {
  const WealthSnapshot({
    this.version = current,
    this.currency = '',
    this.asOf = '',
    this.holdingsCount = 0,
    this.holdingsTotal = 0,
    this.byClass = const [],
    this.netWorth = const [],
    this.exposure = const [],
  });

  static const current = 1;

  /// The one row Samriddhi keeps up to date.
  static const rowId = 'samriddhi.wealth';

  final int version;
  final String currency, asOf;
  final int holdingsCount, holdingsTotal;
  final List<ClassValue> byClass;

  /// Oldest month first.
  final List<MonthValue> netWorth;
  final List<Exposure> exposure;

  bool get isEmpty => currency.isEmpty;

  /// The newest month's net worth, or null when none is known.
  MonthValue? get latestNetWorth => netWorth.isEmpty ? null : netWorth.last;

  factory WealthSnapshot.parse(String text) {
    final json = _object(text);
    if (json == null) return const WealthSnapshot(version: 0);
    final h = json['holdings'] is Map ? json['holdings'] as Map : const {};
    return WealthSnapshot(
      version: _int(json['v']),
      currency: _str(json['currency']),
      asOf: _str(json['asOf']),
      holdingsCount: _int(h['count']),
      holdingsTotal: _int(h['total']),
      byClass: [
        for (final m in _maps(h['byClass']))
          if (_str(m['assetClass']).isNotEmpty) (assetClass: _str(m['assetClass']), value: _int(m['value'])),
      ],
      netWorth: [
        for (final m in _maps(json['netWorth']))
          if (_str(m['month']).isNotEmpty) (month: _str(m['month']), value: _int(m['value'])),
      ],
      exposure: [
        for (final m in _maps(json['exposure']))
          if (_str(m['kind']).isNotEmpty && _str(m['key']).isNotEmpty)
            (kind: _str(m['kind']), key: _str(m['key']), value: _int(m['value'])),
      ],
    );
  }

  String encode() => jsonEncode({
    'v': current,
    'currency': currency,
    'asOf': asOf,
    'holdings': {
      'count': holdingsCount,
      'total': holdingsTotal,
      'byClass': [
        for (final c in byClass) {'assetClass': c.assetClass, 'value': c.value},
      ],
    },
    'netWorth': [
      for (final m in netWorth) {'month': m.month, 'value': m.value},
    ],
    'exposure': [
      for (final e in exposure) {'kind': e.kind, 'key': e.key, 'value': e.value},
    ],
  });
}

Map<Object?, Object?>? _object(String text) {
  try {
    final v = jsonDecode(text);
    return v is Map ? v : null;
  } on FormatException {
    return null;
  }
}

String _str(Object? v) => v is String ? v : '';

/// Whole numbers only: an amount that is not exact reads as 0.
int _int(Object? v) => v is int ? v : 0;

List<Map<Object?, Object?>> _maps(Object? v) => [if (v is List) ...v.whereType<Map<Object?, Object?>>()];
