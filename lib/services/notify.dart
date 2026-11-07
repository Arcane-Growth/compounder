import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import '../llm/llm.dart';

const _channel = AndroidNotificationDetails(
  'compounder_coach',
  'Daily coach',
  channelDescription: 'A once-a-day message from your Compounder coach',
  importance: Importance.defaultImportance,
  priority: Priority.defaultPriority,
);

const _id = 42;

/// Start of the 7-day digest window: local midnight six calendar days before
/// [now]. Calendar arithmetic, not `Duration(days: 6)`: a 144-hour subtraction
/// from midnight lands on 23:00/01:00 across a DST boundary.
DateTime digestWindowStart(DateTime now) =>
    DateTime(now.year, now.month, now.day - 6);

/// Whole calendar days between [now] and [then], counted on UTC day keys.
///
/// `now.difference(then).inDays` is elapsed-hours truncated to days, so a
/// 3-calendar-day gap across a DST boundary computes as 2. Local-midnight
/// subtraction has the same defect (the difference is still a Duration);
/// UTC day keys have no transitions, so the count is exact.
int calendarDaysSince(DateTime now, DateTime then) =>
    DateTime.utc(now.year, now.month, now.day)
        .difference(DateTime.utc(then.year, then.month, then.day))
        .inDays;

/// Next delivery time for the daily coach digest.
///
/// Returns today at [coachMinutes] when that is still in the future, otherwise
/// tomorrow at the same wall-clock time. Calendar arithmetic keeps the
/// wall-clock time across DST boundaries; `add(Duration(days: 1))` shifted it
/// by an hour in both directions.
///
/// On a fall-back day the configured wall-clock time can occur twice. The
/// constructor resolves to the first (DST) occurrence, so if that one has
/// already passed but the repeated occurrence is still ahead, the digest is
/// scheduled for the repeated one instead of being pushed to tomorrow
/// (pre-existing observation in the M3 gate).
DateTime nextDigestAt(DateTime now, int coachMinutes) {
  final hour = coachMinutes ~/ 60;
  final minute = coachMinutes % 60;
  final today = DateTime(now.year, now.month, now.day, hour, minute);
  if (today.isAfter(now)) return today;
  // One absolute hour later lands on the same wall-clock time only when the
  // clock went back in between, i.e. this wall-clock time occurs twice today.
  final repeated = today.add(const Duration(hours: 1));
  if (repeated.hour == hour &&
      repeated.minute == minute &&
      repeated.isAfter(now)) {
    return repeated;
  }
  return DateTime(now.year, now.month, now.day + 1, hour, minute);
}

class NotifyService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz
          .getLocation((await FlutterTimezone.getLocalTimezone()).identifier));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }
    await _plugin.initialize(
      const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _ready = true;
  }

  /// Deterministic 7-day summary across all four domains.
  static String buildDigest(AppStore store, {DateTime? now}) {
    final anchor = now ?? DateTime.now();
    final from = digestWindowStart(anchor);
    final fromMs = from.millisecondsSinceEpoch;

    final finished = store.history.where((h) => h.startedAt >= fromMs).toList();
    final lastWorkout = store.history.isEmpty ? null : store.history.first;
    final daysSinceWorkout = lastWorkout == null
        ? null
        : calendarDaysSince(
            anchor, DateTime.fromMillisecondsSinceEpoch(lastWorkout.startedAt));

    final recentMeals =
        store.meals.where((m) => m.timestamp >= fromMs).toList();
    final avgCal = recentMeals.isEmpty
        ? 0.0
        : recentMeals.fold(0.0, (a, m) => a + m.calories) / recentMeals.length;
    final goal = store.goals;

    final recentMoods =
        store.moods.where((m) => m.timestamp >= fromMs).toList();
    final avgMood = Mind.averageMood(recentMoods.map((m) => m.mood).toList());
    final streak = Mind.moodStreak(store.moods
        .map((m) => DateTime.fromMillisecondsSinceEpoch(m.timestamp))
        .toList());

    final parts = <String>[];

    if (finished.isEmpty && daysSinceWorkout != null && daysSinceWorkout >= 3) {
      parts.add(
          'You have not lifted in $daysSinceWorkout days — time to get back to the gym.');
    } else if (finished.isNotEmpty) {
      final volume = finished.fold(0.0, (a, h) => a + h.totalKg);
      parts.add(
          '${finished.length} workout${finished.length == 1 ? '' : 's'} this week '
          '(${trimZero(volume)} kg total volume).');
    } else {
      parts.add('No workouts logged yet this week — even 20 minutes counts.');
    }

    if (recentMeals.isEmpty) {
      parts.add(
          'No meals logged recently — time to get back on track with food.');
    } else {
      parts.add(
          '${recentMeals.length} meals logged, averaging ${avgCal.round()} kcal '
          '(goal ${goal.calories.round()}).');
    }

    if (avgMood != null && avgMood < 2.5) {
      parts.add(
          'Your mood has been low this week — be gentle with yourself, and consider a quiet session.');
    } else if (streak >= 3) {
      parts.add('You have checked in with your mood $streak days in a row.');
    }

    return parts.join(' ');
  }

  static Future<String> polishDigest(AppStore store) async {
    final facts = buildDigest(store);
    final ai = store.ai;
    if (!ai.configured) return facts;
    try {
      final polished = await ChatClient(ai.baseUrl, ai.apiKey, ai.model)
          .simple(
            'You are Compounder\'s personal life coach writing a daily push notification. '
            'Rewrite the user\'s stats as one short, warm, motivating sentence (under 140 chars). '
            'Only use the provided numbers; never invent data.',
            facts,
          )
          .timeout(const Duration(seconds: 15));
      return polished.isEmpty || polished.length > 300 ? facts : polished;
    } catch (_) {
      return facts;
    }
  }

  /// Schedules the next delivery at the configured time with fresh text.
  /// Re-running this on app start keeps the digest current.
  Future<void> rescheduleDaily(AppStore store) async {
    await init();
    if (!store.coachEnabled) {
      await _plugin.cancel(_id);
      return;
    }
    final now = DateTime.now();
    final when = nextDigestAt(now, store.coachMinutes);
    final tzWhen = tz.TZDateTime.from(when, tz.local);

    // Schedule instantly with the on-device digest; then (never blocking the
    // caller) upgrade the text with an AI polish when the endpoint answers.
    await _scheduleDigest(tzWhen, NotifyService.buildDigest(store));
    unawaited(() async {
      try {
        final polished = await polishDigest(store);
        await _scheduleDigest(tzWhen, polished);
      } catch (_) {}
    }());
  }

  Future<void> _scheduleDigest(tz.TZDateTime when, String body) async {
    try {
      await _plugin.zonedSchedule(
        _id,
        'Compounder coach',
        body,
        when,
        const NotificationDetails(android: _channel),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {
      // Exact alarms can be denied by the OS; fall back to an inexact schedule.
      await _plugin.zonedSchedule(
        _id,
        'Compounder coach',
        body,
        when,
        const NotificationDetails(android: _channel),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }
  }

  Future<void> _showNow(String body) async {
    await _plugin.show(
      _id + 1,
      'Compounder coach',
      body,
      const NotificationDetails(android: _channel),
    );
  }

  Future<void> scheduleReminder(Reminder reminder) async {
    await init();
    final when = DateTime.fromMillisecondsSinceEpoch(reminder.dueAt);
    if (!when.isAfter(DateTime.now())) return;
    final details = const NotificationDetails(android: _channel);
    final tzWhen = tz.TZDateTime.from(when, tz.local);
    try {
      await _plugin.zonedSchedule(
        1000 + reminder.id,
        'Compounder reminder',
        reminder.text,
        tzWhen,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {
      await _plugin.zonedSchedule(
        1000 + reminder.id,
        'Compounder reminder',
        reminder.text,
        tzWhen,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

  Future<void> cancelReminder(int reminderId) async {
    await init();
    await _plugin.cancel(1000 + reminderId);
  }

  /// Re-schedules every pending reminder in [store].
  ///
  /// Reminders live in the database, but the OS notification is only created
  /// when the coach tool schedules it. After a backup import the rows are
  /// restored without their notifications, so the user sees them in Settings
  /// and assumes they will fire (audit backup MINOR-4). Idempotent: each
  /// reminder reuses its own notification id.
  Future<void> rescheduleReminders(AppStore store) async {
    await init();
    for (final reminder in store.reminders) {
      try {
        await scheduleReminder(reminder);
      } catch (_) {
        // One bad reminder must not stop the rest from being scheduled.
      }
    }
  }

  Future<void> testNotification(AppStore store) async {
    await init();
    await _showNow(await polishDigest(store));
  }
}
