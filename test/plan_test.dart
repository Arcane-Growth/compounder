import 'dart:io';

import 'package:compounder/data/store.dart';
import 'package:compounder/domain/activity.dart';
import 'package:compounder/domain/plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Day planner proofs: block validation, chronological ordering (including the
/// same-start tie-break), current/next block detection against an injected
/// clock, DST-safe day keys, and store CRUD with day scoping.

PlanBlock block({
  int id = 1,
  String day = '2026-11-09',
  String title = 'Deep work',
  int startMin = 540,
  int endMin = 600,
  bool done = false,
  int? doneAt,
  int createdAt = 0,
  int position = 0,
}) =>
    PlanBlock(
      id: id,
      day: day,
      title: title,
      startMin: startMin,
      endMin: endMin,
      done: done,
      doneAt: doneAt,
      createdAt: createdAt,
      position: position,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUpAll(tzdata.initializeTimeZones);

  tz.Location ny() => tz.getLocation('America/New_York');

  group('block validation', () {
    test('accepts a normal block', () {
      expect(
          planBlockError(title: 'Deep work', startMin: 540, endMin: 600),
          isNull);
    });

    test('rejects a blank or whitespace-only title', () {
      expect(planBlockError(title: '', startMin: 0, endMin: 60), isNotNull);
      expect(planBlockError(title: '   ', startMin: 0, endMin: 60), isNotNull);
    });

    test('rejects a title longer than the cap', () {
      final long = 'x' * (planTitleMaxLength + 1);
      expect(planBlockError(title: long, startMin: 0, endMin: 60), isNotNull);
      final atCap = 'x' * planTitleMaxLength;
      expect(planBlockError(title: atCap, startMin: 0, endMin: 60), isNull);
    });

    test('rejects out-of-range start and end minutes', () {
      expect(planBlockError(title: 't', startMin: -1, endMin: 60), isNotNull);
      expect(planBlockError(title: 't', startMin: 0, endMin: -1), isNotNull);
      expect(
          planBlockError(title: 't', startMin: 0, endMin: minutesPerDay + 1),
          isNotNull);
      expect(
          planBlockError(title: 't', startMin: minutesPerDay + 1, endMin: 1440),
          isNotNull);
    });

    test('rejects an end at or before the start', () {
      expect(planBlockError(title: 't', startMin: 600, endMin: 600), isNotNull);
      expect(planBlockError(title: 't', startMin: 600, endMin: 540), isNotNull);
    });

    test('allows a block that runs to midnight', () {
      expect(
          planBlockError(title: 'Wind down', startMin: 1380, endMin: 1440),
          isNull);
    });
  });

  group('chronological ordering', () {
    test('sorts by start time', () {
      final ordered = chronological([
        block(id: 1, startMin: 600, endMin: 660),
        block(id: 2, startMin: 480, endMin: 540),
        block(id: 3, startMin: 540, endMin: 600),
      ]);
      expect(ordered.map((b) => b.startMin).toList(), [480, 540, 600]);
    });

    test('breaks a same-start tie by position, then id', () {
      final ordered = chronological([
        block(id: 9, startMin: 540, endMin: 600, position: 2),
        block(id: 4, startMin: 540, endMin: 600, position: 1),
        block(id: 2, startMin: 540, endMin: 600, position: 1),
      ]);
      expect(ordered.map((b) => b.id).toList(), [2, 4, 9],
          reason: 'position then id must make the order deterministic');
    });

    test('does not mutate the input list', () {
      final input = [
        block(id: 1, startMin: 600, endMin: 660),
        block(id: 2, startMin: 480, endMin: 540),
      ];
      chronological(input);
      expect(input.map((b) => b.id).toList(), [1, 2]);
    });
  });

  group('current and next block', () {
    final now = DateTime(2026, 11, 9, 10, 30); // minute 630

    test('finds the block containing now', () {
      final current = currentBlock([
        block(id: 1, startMin: 600, endMin: 660),
        block(id: 2, startMin: 660, endMin: 720),
      ], now);
      expect(current?.id, 1);
    });

    test('a block is current from its start inclusive', () {
      final atStart = DateTime(2026, 11, 9, 10, 0);
      expect(currentBlock([block(startMin: 600, endMin: 660)], atStart)?.id, 1);
    });

    test('a block is not current at its end (exclusive)', () {
      final atEnd = DateTime(2026, 11, 9, 11, 0);
      expect(currentBlock([block(startMin: 600, endMin: 660)], atEnd), isNull);
    });

    test('ignores blocks on another day', () {
      final current = currentBlock([
        block(id: 1, day: '2026-11-08', startMin: 600, endMin: 660),
      ], now);
      expect(current, isNull);
    });

    test('next block starts strictly after now', () {
      final next = nextBlock([
        block(id: 1, startMin: 600, endMin: 660),
        block(id: 2, startMin: 660, endMin: 720),
        block(id: 3, startMin: 780, endMin: 840),
      ], now);
      expect(next?.id, 2,
          reason: 'a block starting at the current minute is not "next"');
    });

    test('returns null when nothing is later today', () {
      expect(
          nextBlock([block(startMin: 480, endMin: 540)], now), isNull);
    });

    test('dayHasPlan is true only for a day with a block', () {
      final blocks = [block(day: '2026-11-09')];
      expect(dayHasPlan(blocks, DateTime(2026, 11, 9, 23, 59)), isTrue);
      expect(dayHasPlan(blocks, DateTime(2026, 11, 10)), isFalse);
    });
  });

  group('DST-safe day keys', () {
    test('spring-forward instants stay on the same calendar day', () {
      // 2026-03-08 02:00 EST -> 03:00 EDT in America/New_York.
      final before = tz.TZDateTime(ny(), 2026, 3, 8, 1, 30);
      final after = tz.TZDateTime(ny(), 2026, 3, 8, 3, 30);
      expect(planDayKey(before), '2026-03-08');
      expect(planDayKey(after), '2026-03-08',
          reason: 'a DST shift must not move the day key');
      // A block on that day is found from both instants.
      final blocks = [block(day: '2026-03-08', startMin: 60, endMin: 120)];
      expect(dayHasPlan(blocks, before), isTrue);
      expect(dayHasPlan(blocks, after), isTrue);
    });

    test('fall-back instants stay on the same calendar day', () {
      // 2026-11-01 02:00 EDT -> 01:00 EST in America/New_York: 01:30 happens
      // twice. Constructing the ambiguous local time twice resolves to the same
      // instant, so step an hour forward to reach the second (EST) 01:30.
      final firstOneThirty = tz.TZDateTime(ny(), 2026, 11, 1, 1, 30);
      final secondOneThirty = firstOneThirty.add(const Duration(hours: 1));
      expect(firstOneThirty.timeZoneOffset, const Duration(hours: -4),
          reason: 'the first 01:30 is EDT');
      expect(secondOneThirty.timeZoneOffset, const Duration(hours: -5),
          reason: 'the second 01:30 is EST — the test must cross the boundary');
      expect(secondOneThirty.hour, 1);
      expect(secondOneThirty.minute, 30);
      expect(planDayKey(firstOneThirty), '2026-11-01');
      expect(planDayKey(secondOneThirty), '2026-11-01');
      // The day after the transition is a distinct key.
      expect(planDayKey(tz.TZDateTime(ny(), 2026, 11, 2)), '2026-11-02');
    });

    test('planDayKey matches the shared habit day key', () {
      final day = DateTime(2026, 11, 9, 23, 59);
      expect(planDayKey(day), '2026-11-09');
    });
  });

  group('time formatting', () {
    test('formats minutes from midnight as HH:MM', () {
      expect(formatPlanTime(0), '00:00');
      expect(formatPlanTime(540), '09:00');
      expect(formatPlanTime(1439), '23:59');
      expect(formatPlanTime(1440), '24:00');
    });

    test('formats durations compactly', () {
      expect(formatPlanDuration(45), '45 min');
      expect(formatPlanDuration(60), '1h');
      expect(formatPlanDuration(90), '1h 30m');
      expect(formatPlanDuration(0), '0 min');
    });
  });

  group('store CRUD', () {
    late AppStore store;
    late String path;
    late Directory tmp;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tmp = await Directory.systemTemp.createTemp('compounder_plan_test');
      path = p.join(tmp.path, 'plan.db');
      store = await AppStore.open(prefs, path: path);
    });

    tearDown(() async {
      await store.db.close();
      await databaseFactory.deleteDatabase(path);
      await tmp.delete(recursive: true);
    });

    test('create, read, update, complete and delete a block', () async {
      final day = DateTime(2026, 11, 9);
      final id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 540, endMin: 600);
      expect(id, greaterThan(0));

      var blocks = await store.planBlocksForDay(day);
      expect(blocks, hasLength(1));
      expect(blocks.single.title, 'Deep work');
      expect(blocks.single.startMin, 540);
      expect(blocks.single.endMin, 600);
      expect(blocks.single.done, isFalse);
      expect(blocks.single.doneAt, isNull);
      expect(blocks.single.durationMinutes, 60);

      await store.updatePlanBlock(id,
          title: 'Deep work v2', startMin: 600, endMin: 690);
      blocks = await store.planBlocksForDay(day);
      expect(blocks.single.title, 'Deep work v2');
      expect(blocks.single.startMin, 600);
      expect(blocks.single.endMin, 690);

      await store.setPlanBlockDone(id, true);
      blocks = await store.planBlocksForDay(day);
      expect(blocks.single.done, isTrue);
      expect(blocks.single.doneAt, isNotNull);

      await store.setPlanBlockDone(id, false);
      blocks = await store.planBlocksForDay(day);
      expect(blocks.single.done, isFalse);
      expect(blocks.single.doneAt, isNull);

      await store.deletePlanBlock(id);
      expect(await store.planBlocksForDay(day), isEmpty);
    });

    test('blocks are scoped to their day and ordered chronologically',
        () async {
      final day = DateTime(2026, 11, 9);
      final other = DateTime(2026, 11, 10);
      await store.createPlanBlock(
          day: day, title: 'Late', startMin: 600, endMin: 660);
      await store.createPlanBlock(
          day: day, title: 'Early', startMin: 480, endMin: 540);
      await store.createPlanBlock(
          day: other, title: 'Other day', startMin: 300, endMin: 360);

      final blocks = await store.planBlocksForDay(day);
      expect(blocks.map((b) => b.title).toList(), ['Early', 'Late'],
          reason: 'the day query must be chronological and day-scoped');
      expect(blocks.every((b) => b.day == '2026-11-09'), isTrue);
      expect((await store.planBlocksForDay(other)).single.title, 'Other day');
    });

    test('same-start blocks keep a deterministic position order', () async {
      final day = DateTime(2026, 11, 9);
      final first = await store.createPlanBlock(
          day: day, title: 'A', startMin: 540, endMin: 600);
      final second = await store.createPlanBlock(
          day: day, title: 'B', startMin: 540, endMin: 600);
      final blocks = await store.planBlocksForDay(day);
      expect(blocks.map((b) => b.id).toList(), [first, second]);
    });

    test('invalid blocks are rejected with a StoreException', () async {
      final day = DateTime(2026, 11, 9);
      await expectLater(
          store.createPlanBlock(
              day: day, title: '  ', startMin: 540, endMin: 600),
          throwsA(isA<StoreException>()));
      await expectLater(
          store.createPlanBlock(
              day: day, title: 't', startMin: 600, endMin: 600),
          throwsA(isA<StoreException>()));
      await expectLater(
          store.createPlanBlock(
              day: day, title: 't', startMin: -1, endMin: 60),
          throwsA(isA<StoreException>()));
      expect(await store.planBlocksForDay(day), isEmpty);

      final id = await store.createPlanBlock(
          day: day, title: 'Keep', startMin: 540, endMin: 600);
      await expectLater(
          store.updatePlanBlock(id, endMin: 500),
          throwsA(isA<StoreException>()));
      final blocks = await store.planBlocksForDay(day);
      expect(blocks.single.title, 'Keep');
      expect(blocks.single.endMin, 600,
          reason: 'a rejected update must not write a partial row');
    });

    test('updating an unknown block is a no-op', () async {
      await store.updatePlanBlock(999, title: 'Ghost');
      expect(await store.db.query('plan_blocks'), isEmpty);
    });

    test('a plan block counts toward the planning pillar', () async {
      final day = DateTime(2026, 11, 9);
      await store.createPlanBlock(
          day: day, title: 'Plan', startMin: 480, endMin: 510);
      final days = await store.dailyPillarActivity(day, DateTime(2026, 11, 10));
      final planned = days['2026-11-09']!;
      expect(planned.planCount, 1);
      expect(planned.hasPillar(pillarPlan), isTrue);
      expect(planned.intensity, 1);
    });
  });
}
