import 'dart:convert';

import 'package:compounder/coach/tools.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression tests for the two findings in review/b2b3b4m1-review.md that
/// concern the coach's `getNetWorthHistory` tool:
///
///  * F2 — same-timestamp balance snapshots were ordered non-deterministically
///    in `snapshotSeries()` and `netWorthSeries`, so the tool and the Wealth
///    screen could disagree and neither was reproducible.
///  * F1 — the tool resolved liability status from the cached `store.accounts`
///    list instead of the DB, so a snapshot whose account was not in the cache
///    was silently dropped.
///
/// Both are asserted as *parity*: the tool must produce exactly what the
/// Wealth screen's `netWorthSeries` produces from the same DB rows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String dbPath;
  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dbPath = '${await databaseFactory.getDatabasesPath()}/networth_parity.db';
    await databaseFactory.deleteDatabase(dbPath);
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: dbPath);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  /// The reference the Wealth screen renders, bucketed by month exactly as the
  /// tool buckets it. Built from a fresh DB query (the same join `refreshAll`
  /// uses) so it is independent of any cached state, and it compiles against
  /// the pre-fix code too — which is what lets these guards fail behaviourally
  /// rather than at compile time.
  Future<List<Map<String, Object?>>> referencePoints() async {
    final rows = await store.db.rawQuery('''
        SELECT s.account_id, s.balance, s.taken_at, a.type
        FROM balance_snapshots s
        JOIN accounts a ON a.id = s.account_id
        ORDER BY s.taken_at''');
    final series = netWorthSeries(rows
        .map((r) => (
              accountId: r['account_id'] as int,
              balance: (r['balance'] as num).toDouble(),
              isLiability: (r['type'] as String) == 'Debt',
              takenAt: r['taken_at'] as int,
            ))
        .toList());
    final byMonth = <String, double>{};
    for (final p in series) {
      final taken = DateTime.fromMillisecondsSinceEpoch(p.date);
      final month = '${taken.year}-${taken.month.toString().padLeft(2, '0')}';
      byMonth[month] = p.value;
    }
    final months = byMonth.keys.toList()..sort();
    return [
      for (final m in months) {'month': m, 'netWorth': num1(byMonth[m]!)}
    ];
  }

  Future<List<Map<String, Object?>>> toolPoints() async {
    final raw = await NetWorthHistoryTool(store).run(const {});
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    return (decoded['points'] as List).cast<Map<String, Object?>>();
  }

  group('F2 same-timestamp snapshots are deterministic and match the chart',
      () {
    test('40 tied snapshots: tool equals the netWorthSeries reference',
        () async {
      // Two accounts, 40 snapshots all at one identical instant. Balances are
      // inserted in descending order so SQLite's rowid order and the sorted
      // order disagree: a fold that depends on visit order picks a different
      // month-end balance. The deterministic tiebreak is
      // (takenAt, accountId, balance), so the last row per account is its
      // highest balance: 1019 asset - 438 debt = 581.
      final takenAt = DateTime(2026, 11, 15, 12).millisecondsSinceEpoch;
      final bankId = await store.db.insert('accounts', {
        'name': 'Savings',
        'type': 'Bank',
        'balance': 1039.0,
        'currency': 'USD',
        'updated_at': takenAt,
      });
      final debtId = await store.db.insert('accounts', {
        'name': 'Card',
        'type': 'Debt',
        'balance': 478.0,
        'currency': 'USD',
        'updated_at': takenAt,
      });
      for (var i = 19; i >= 0; i--) {
        await store.db.insert('balance_snapshots', {
          'account_id': bankId,
          'balance': 1000.0 + i,
          'taken_at': takenAt,
        });
        await store.db.insert('balance_snapshots', {
          'account_id': debtId,
          'balance': 400.0 + 2 * i,
          'taken_at': takenAt,
        });
      }
      await store.refreshAll();

      final reference = await referencePoints();
      expect(
          reference,
          [
            {'month': '2026-11', 'netWorth': '581'}
          ],
          reason:
              'the tiebreak must resolve to the highest balance per account');

      final points = await toolPoints();
      expect(points, reference,
          reason: 'the coach tool must agree with the Wealth screen exactly');

      // Stability under a different physical row order: delete and re-insert
      // the same 40 snapshots so the rowid order now disagrees with the
      // deterministic tiebreak in the other direction (highest bank balance
      // last, lowest debt balance last). A fold that depended on visit order
      // would report 1019 - 400 = 619 here. The old loop re-ran the same query
      // against unchanged rows and could not fail (review b2b3b4m1 MINOR-3).
      await store.db.delete('balance_snapshots');
      for (var i = 0; i < 20; i++) {
        await store.db.insert('balance_snapshots', {
          'account_id': bankId,
          'balance': 1000.0 + i,
          'taken_at': takenAt,
        });
      }
      for (var i = 19; i >= 0; i--) {
        await store.db.insert('balance_snapshots', {
          'account_id': debtId,
          'balance': 400.0 + 2 * i,
          'taken_at': takenAt,
        });
      }
      await store.refreshAll();
      expect(
          await toolPoints(),
          [
            {'month': '2026-11', 'netWorth': '581'}
          ],
          reason: 'a different physical row order must not change the result');
    });

    test('netWorthSeries is order-independent for tied timestamps', () {
      // Same 40 tied snapshots, fed in two different input orders. Dart's
      // List.sort is not stable, so sorting on takenAt alone made the result
      // depend on the input order.
      final entries =
          <({int accountId, double balance, bool isLiability, int takenAt})>[
        for (var i = 0; i < 20; i++)
          (accountId: 1, balance: 1000.0 + i, isLiability: false, takenAt: 500),
        for (var i = 0; i < 20; i++)
          (
            accountId: 2,
            balance: 400.0 + 2 * i,
            isLiability: true,
            takenAt: 500
          ),
      ];
      final forward = netWorthSeries(entries);
      final reversed = netWorthSeries(entries.reversed.toList());
      expect(forward.length, reversed.length);
      for (var i = 0; i < forward.length; i++) {
        expect(reversed[i].value, forward[i].value,
            reason: 'point $i must not depend on input order');
      }
      expect(forward.last.value, closeTo(581, 0.001));
    });
  });

  group('F1 tool reads the DB, not the stale accounts cache', () {
    test('a snapshot written without refreshAll is still reported', () async {
      // Shape 6 from the review: account + snapshot inserted straight into the
      // DB, so store.accounts is stale. The tool must still see the row.
      final takenAt = DateTime(2026, 11, 15, 12).millisecondsSinceEpoch;
      final bankId = await store.db.insert('accounts', {
        'name': 'Savings',
        'type': 'Bank',
        'balance': 1000.0,
        'currency': 'USD',
        'updated_at': takenAt,
      });
      final debtId = await store.db.insert('accounts', {
        'name': 'Card',
        'type': 'Debt',
        'balance': 250.0,
        'currency': 'USD',
        'updated_at': takenAt,
      });
      await store.db.insert('balance_snapshots', {
        'account_id': bankId,
        'balance': 1000.0,
        'taken_at': takenAt,
      });
      await store.db.insert('balance_snapshots', {
        'account_id': debtId,
        'balance': 250.0,
        'taken_at': takenAt,
      });
      // Deliberately no refreshAll(): the cache still has no accounts.

      final points = await toolPoints();
      expect(
          points,
          [
            {'month': '2026-11', 'netWorth': '750'}
          ],
          reason: 'the tool must derive the series from the DB, not the cache');
      expect(points, await referencePoints(),
          reason: 'tool and chart must agree even with a stale cache');
    });
  });
}
