import 'habits.dart';

/// Minutes in a local day. Block times are minutes from local midnight, so the
/// last representable end is [minutesPerDay] (midnight at the start of the next
/// day).
const int minutesPerDay = 1440;

/// Longest accepted block title. Long enough for a real task description, short
/// enough that the planner tile stays readable at accessibility text scales.
const int planTitleMaxLength = 80;

/// The local day key for [day], discarding any time component.
///
/// Deliberately an alias for [habitDayKey], exactly like `localDayKey` in
/// activity.dart: the planner, the habit tracker and the activity heatmap must
/// agree on what "a day" means, and one shared implementation is the only way
/// to guarantee that. The separate name documents the domain boundary; it is
/// not an independent implementation.
String planDayKey(DateTime day) => habitDayKey(day);

/// One timed block on a day's plan.
///
/// [day] is a local `YYYY-MM-DD` key (see [planDayKey]), never an epoch
/// timestamp: a block belongs to a calendar day, and a timestamp would shift
/// across timezones and DST. [startMin] and [endMin] are minutes from local
/// midnight, so a block is stored without a timezone at all.
class PlanBlock {
  final int id;
  final String day;
  final String title;
  final int startMin;
  final int endMin;
  final bool done;
  final int? doneAt;
  final int createdAt;
  final int position;

  const PlanBlock({
    required this.id,
    required this.day,
    required this.title,
    required this.startMin,
    required this.endMin,
    this.done = false,
    this.doneAt,
    required this.createdAt,
    this.position = 0,
  });

  factory PlanBlock.fromMap(Map<String, Object?> m) => PlanBlock(
        id: m['id'] as int,
        day: m['day'] as String,
        title: m['title'] as String,
        startMin: m['start_min'] as int,
        endMin: m['end_min'] as int,
        done: (m['done'] as int? ?? 0) == 1,
        doneAt: m['done_at'] as int?,
        createdAt: m['created_at'] as int,
        position: m['position'] as int? ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != 0) 'id': id,
        'day': day,
        'title': title,
        'start_min': startMin,
        'end_min': endMin,
        'done': done ? 1 : 0,
        'done_at': doneAt,
        'created_at': createdAt,
        'position': position,
      };

  /// Length of the block in minutes. Always positive for a validated block.
  int get durationMinutes => endMin - startMin;
}

/// Validates a block's editable fields. Returns a user-facing message, or null
/// when the block is valid.
///
/// This is the single validation boundary: the planner dialog shows the message
/// inline and the store re-runs it before writing, so a coach tool or a future
/// import cannot persist a block the UI would reject.
String? planBlockError({
  required String title,
  required int startMin,
  required int endMin,
}) {
  final clean = title.trim();
  if (clean.isEmpty) return 'Enter a title for this block.';
  if (clean.length > planTitleMaxLength) {
    return 'Keep the title under $planTitleMaxLength characters.';
  }
  if (startMin < 0 || startMin > minutesPerDay) {
    return 'Start time must be within the day.';
  }
  if (endMin < 0 || endMin > minutesPerDay) {
    return 'End time must be within the day.';
  }
  if (endMin <= startMin) return 'End time must be after the start time.';
  return null;
}

/// Chronological order for a day's blocks: start time, then the stored
/// position, then the row id.
///
/// The position and id tie-breakers make the order deterministic for two blocks
/// that start at the same minute, so the list cannot reshuffle between builds.
List<PlanBlock> chronological(List<PlanBlock> blocks) {
  final sorted = [...blocks]..sort((a, b) {
      final byStart = a.startMin.compareTo(b.startMin);
      if (byStart != 0) return byStart;
      final byPosition = a.position.compareTo(b.position);
      if (byPosition != 0) return byPosition;
      return a.id.compareTo(b.id);
    });
  return sorted;
}

/// The block containing [now] on [now]'s local day, or null.
///
/// The clock is injected: pure logic never calls [DateTime.now]. A block is
/// current from its start (inclusive) until its end (exclusive), so two
/// back-to-back blocks never both claim the same minute.
PlanBlock? currentBlock(List<PlanBlock> blocks, DateTime now) {
  final key = planDayKey(now);
  final minute = now.hour * 60 + now.minute;
  for (final block in chronological(blocks)) {
    if (block.day != key) continue;
    if (minute >= block.startMin && minute < block.endMin) return block;
  }
  return null;
}

/// The first block on [now]'s local day that starts strictly after [now], or
/// null when the day has no later block.
PlanBlock? nextBlock(List<PlanBlock> blocks, DateTime now) {
  final key = planDayKey(now);
  final minute = now.hour * 60 + now.minute;
  for (final block in chronological(blocks)) {
    if (block.day != key) continue;
    if (block.startMin > minute) return block;
  }
  return null;
}

/// True when [blocks] contains at least one block for [day]'s local day.
///
/// A day counts as planned when it has a block, matching the store's pillar
/// aggregation: the pillar is "you planned the day", not "you finished it".
bool dayHasPlan(List<PlanBlock> blocks, DateTime day) {
  final key = planDayKey(day);
  return blocks.any((b) => b.day == key);
}

/// `HH:MM` for a minute offset from local midnight, 24-hour clock.
///
/// [minutesPerDay] renders as `24:00`, which is the correct end for a block
/// that runs to midnight.
String formatPlanTime(int minutes) {
  final clamped = minutes.clamp(0, minutesPerDay);
  final h = clamped ~/ 60;
  final m = clamped % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// Compact duration label: `45 min`, `1h`, `1h 30m`.
String formatPlanDuration(int minutes) {
  if (minutes <= 0) return '0 min';
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
