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

class NotifyService {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(await FlutterTimezone.getLocalTimezone()));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }
    await _plugin.initialize(
      const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _ready = true;
  }

  /// Deterministic 7-day summary across all four domains.
  static String buildDigest(AppStore store) {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));
    final fromMs = from.millisecondsSinceEpoch;

    final finished = store.history.where((h) => h.startedAt >= fromMs).toList();
    final lastWorkout = store.history.isEmpty ? null : store.history.first;
    final daysSinceWorkout = lastWorkout == null
        ? null
        : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastWorkout.startedAt)).inDays;

    final recentMeals = store.meals.where((m) => m.timestamp >= fromMs).toList();
    final avgCal = recentMeals.isEmpty ? 0.0 : recentMeals.fold(0.0, (a, m) => a + m.calories) / recentMeals.length;
    final goal = store.goals;

    final recentMoods = store.moods.where((m) => m.timestamp >= fromMs).toList();
    final avgMood = Mind.averageMood(recentMoods.map((m) => m.mood).toList());
    final streak = Mind.moodStreak(
        store.moods.map((m) => DateTime.fromMillisecondsSinceEpoch(m.timestamp)).toList());

    final parts = <String>[];

    if (finished.isEmpty && daysSinceWorkout != null && daysSinceWorkout >= 3) {
      parts.add('You have not lifted in $daysSinceWorkout days — time to get back to the gym.');
    } else if (finished.isNotEmpty) {
      final volume = finished.fold(0.0, (a, h) => a + h.totalKg);
      parts.add('${finished.length} workout${finished.length == 1 ? '' : 's'} this week '
          '(${trimZero(volume)} kg total volume).');
    } else {
      parts.add('No workouts logged yet this week — even 20 minutes counts.');
    }

    if (recentMeals.isEmpty) {
      parts.add('No meals logged recently — time to get back on track with food.');
    } else {
      parts.add('${recentMeals.length} meals logged, averaging ${avgCal.round()} kcal '
          '(goal ${goal.calories.round()}).');
    }

    if (avgMood != null && avgMood < 2.5) {
      parts.add('Your mood has been low this week — be gentle with yourself, and consider a quiet session.');
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
      ).timeout(const Duration(seconds: 15));
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
    var when = DateTime(now.year, now.month, now.day,
        store.coachMinutes ~/ 60, store.coachMinutes % 60);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
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

  Future<void> testNotification(AppStore store) async {
    await init();
    await _showNow(await polishDigest(store));
  }
}
