import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/store.dart';
import '../db/synced_database.dart';

/// An edit made on this device that a newer edit from another device
/// replaced before this one was sent. Sync is newest-wins per row; without
/// this, the losing edit would vanish without a trace. Kept on this device
/// only (in local_settings), until the person restores or dismisses it.
class KeptEdit {
  const KeptEdit({required this.table, required this.id, required this.row, required this.at});

  final String table;
  final String id;

  /// The row as this device had it, plain values only.
  final Map<String, Object?> row;

  /// When it was replaced (UTC, ISO 8601).
  final String at;

  static const _prefix = 'kept.';
  String get _key => '$_prefix$table.$id';

  /// Short text from the row's own words, for a list: its first few text
  /// values that are not ids or stamps.
  String get preview {
    final words = [
      for (final MapEntry(:key, :value) in row.entries)
        if (value is String &&
            value.trim().isNotEmpty &&
            key != 'id' &&
            key != 'hlc' &&
            !key.endsWith('_id') &&
            !RegExp(r'^[0-9a-f-]{20,}$').hasMatch(value))
          value.trim(),
    ];
    final text = words.take(3).join(' · ');
    return text.length > 120 ? '${text.substring(0, 117)}…' : text;
  }

  /// "job applications" for `job_applications`.
  String get what => table.replaceAll('_', ' ');

  /// Keeps [row] of [table], the version about to be replaced. A second
  /// loss of the same row keeps the latest local version.
  static Future<void> keep(SyncedDatabase db, String table, Map<String, Object?> row) async {
    final plain = {
      for (final MapEntry(:key, :value) in row.entries)
        if (value == null || value is String || value is num || value is bool) key: value,
    };
    final edit = KeptEdit(
      table: table,
      id: '${row['id']}',
      row: plain,
      at: DateTime.now().toUtc().toIso8601String(),
    );
    await db.setLocalSetting(edit._key, jsonEncode({'t': table, 'r': plain, 'at': edit.at}));
  }

  /// Every kept edit on [db], newest first.
  static Future<List<KeptEdit>> all(SyncedDatabase db) async {
    final rows = await db
        .customSelect('SELECT value FROM local_settings WHERE key LIKE ?', variables: [Variable('$_prefix%')])
        .get();
    final out = <KeptEdit>[];
    for (final r in rows) {
      try {
        final m = jsonDecode(r.read<String>('value')) as Map<String, Object?>;
        final row = (m['r']! as Map).cast<String, Object?>();
        out.add(KeptEdit(table: m['t']! as String, id: '${row['id']}', row: row, at: m['at']! as String));
      } on Object {
        // A damaged entry is skipped, never fatal.
      }
    }
    return out..sort((a, b) => b.at.compareTo(a.at));
  }

  static Future<int> count(SyncedDatabase db) async =>
      (await db
              .customSelect(
                'SELECT COUNT(*) AS n FROM local_settings WHERE key LIKE ?',
                variables: [Variable('$_prefix%')],
              )
              .getSingle())
          .read<int>('n');

  /// Puts this version back as a new edit, so it syncs to every device and
  /// wins from now on. Columns the table no longer has are left out.
  Future<void> restore(Store store) async {
    final info = store.db.tableNamed(table);
    if (info == null) throw StateError('No table $table');
    final known = {for (final c in info.$columns) c.name};
    final cols = [
      for (final k in row.keys)
        if (known.contains(k) && k != 'hlc') k,
    ];
    final values = [for (final c in cols) row[c] is bool ? ((row[c]! as bool) ? 1 : 0) : row[c]];
    await store.db.transaction(() async {
      await store.db.customStatement(
        'INSERT INTO "$table" (${cols.map((c) => '"$c"').join(', ')}) '
        'VALUES (${List.filled(cols.length, '?').join(', ')}) '
        'ON CONFLICT(id) DO UPDATE SET ${cols.where((c) => c != 'id').map((c) => '"$c" = excluded."$c"').join(', ')}',
        values,
      );
      await store.touch(info, id);
      await dismiss(store.db);
    });
  }

  /// Forgets it: the newer edit from the other device stays.
  Future<void> dismiss(SyncedDatabase db) =>
      db.customStatement('DELETE FROM local_settings WHERE key = ?', [_key]);
}
