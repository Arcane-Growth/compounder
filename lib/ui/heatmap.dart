import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../domain/activity.dart';
import 'widgets.dart';

/// GitHub-style activity heatmap over the app's four logging pillars.
///
/// Intensity is the number of distinct pillars logged on a local calendar day
/// (0-4), computed by [PillarDay.intensity]. The grid is a dense visualisation,
/// so individual squares are smaller than the 48dp touch-target guideline;
/// every square carries a [Semantics] label and the full screen also offers the
/// per-day detail sheet, which is the accessible path to the same information.

/// The colour ramp for intensity 0-4, theme aware.
Color heatmapColor(BuildContext context, int intensity) {
  final scheme = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (intensity <= 0) {
    return dark ? scheme.surfaceContainerHighest : const Color(0xFFEBEDF0);
  }
  const lightRamp = [
    Color(0xFF9BE9A8),
    Color(0xFF40C463),
    Color(0xFF30A14E),
    Color(0xFF216E39),
  ];
  const darkRamp = [
    Color(0xFF0E4429),
    Color(0xFF006D32),
    Color(0xFF26A641),
    Color(0xFF39D353),
  ];
  final ramp = dark ? darkRamp : lightRamp;
  return ramp[(intensity - 1).clamp(0, 3)];
}

/// One day square. [day] is the local calendar day it represents.
class HeatmapCell extends StatelessWidget {
  final DateTime day;
  final int intensity;
  final double size;
  final VoidCallback? onTap;

  const HeatmapCell({
    super.key,
    required this.day,
    required this.intensity,
    required this.size,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final key = localDayKey(day);
    return Semantics(
      label: '$key: $intensity of 4 pillars logged',
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: heatmapColor(context, intensity),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// "Less → More" legend for the heatmap ramp.
class HeatmapLegend extends StatelessWidget {
  final double swatchSize;

  const HeatmapLegend({super.key, this.swatchSize = 12});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final labelStyle =
        t.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('Less', style: labelStyle),
      const SizedBox(width: 6),
      for (var i = 0; i <= 4; i++) ...[
        Container(
          width: swatchSize,
          height: swatchSize,
          decoration: BoxDecoration(
            color: heatmapColor(context, i),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 3),
      ],
      const SizedBox(width: 3),
      Text('More', style: labelStyle),
    ]);
  }
}

/// The heatmap grid itself.
///
/// [start] and [end] are inclusive local calendar days. Days outside the range
/// are rendered as blank placeholders so weekday rows stay aligned; only
/// in-range days produce a [HeatmapCell], which is what the widget tests count.
class ActivityHeatmap extends StatelessWidget {
  final Map<String, PillarDay> days;
  final DateTime start;
  final DateTime end;
  final double cellSize;
  final double gap;
  final bool showMonthLabels;
  final bool showWeekdayLabels;
  final bool showLegend;
  final bool scrollable;
  final ValueChanged<DateTime>? onDayTap;

  const ActivityHeatmap({
    super.key,
    required this.days,
    required this.start,
    required this.end,
    this.cellSize = 13,
    this.gap = 3,
    this.showMonthLabels = true,
    this.showWeekdayLabels = true,
    this.showLegend = false,
    this.scrollable = true,
    this.onDayTap,
  });

  /// Weeks (Monday-first columns) covering [start]..[end].
  ///
  /// Walks with calendar arithmetic, never `Duration(days: 7)`: a 24-hour step
  /// lands on 23:00 or 01:00 across a DST boundary and would drift the grid.
  static List<List<DateTime>> weeksFor(DateTime start, DateTime end) {
    final first = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    final firstMonday =
        DateTime(first.year, first.month, first.day - (first.weekday - 1));
    final lastSunday =
        DateTime(last.year, last.month, last.day + (7 - last.weekday));
    final columns = <List<DateTime>>[];
    var cursor = firstMonday;
    while (!cursor.isAfter(lastSunday)) {
      final week = <DateTime>[];
      for (var i = 0; i < 7; i++) {
        week.add(cursor);
        cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
      }
      columns.add(week);
    }
    return columns;
  }

  @override
  Widget build(BuildContext context) {
    final columns = weeksFor(start, end);
    final first = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    final columnWidth = cellSize + gap;

    Widget cellFor(DateTime day) {
      final inRange = !day.isBefore(first) && !day.isAfter(last);
      if (!inRange) {
        return SizedBox(width: cellSize, height: cellSize);
      }
      final entry = days[localDayKey(day)];
      return HeatmapCell(
        day: day,
        intensity: entry?.intensity ?? 0,
        size: cellSize,
        onTap: onDayTap == null ? null : () => onDayTap!(day),
      );
    }

    final grid = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showWeekdayLabels) _weekdayLabels(context),
        for (final week in columns)
          Padding(
            padding: EdgeInsets.only(right: gap),
            child: Column(
              children: [
                for (var row = 0; row < week.length; row++) ...[
                  cellFor(week[row]),
                  if (row < week.length - 1) SizedBox(height: gap),
                ],
              ],
            ),
          ),
      ],
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showMonthLabels) _monthLabels(context, columns, columnWidth),
        grid,
        if (showLegend) ...[
          const SizedBox(height: 12),
          const HeatmapLegend(),
        ],
      ],
    );

    if (!scrollable) return content;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: content,
    );
  }

  Widget _weekdayLabels(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    const names = ['Mon', '', 'Wed', '', 'Fri', '', 'Sun'];
    return Padding(
      padding: EdgeInsets.only(right: gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var row = 0; row < 7; row++) ...[
            SizedBox(
              height: cellSize,
              child: names[row].isEmpty
                  ? null
                  : Align(
                      alignment: Alignment.centerRight,
                      child: Text(names[row], style: style),
                    ),
            ),
            if (row < 6) SizedBox(height: gap),
          ],
        ],
      ),
    );
  }

  Widget _monthLabels(
      BuildContext context, List<List<DateTime>> columns, double columnWidth) {
    final style = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    final labels = <Widget>[];
    var lastMonth = -1;
    for (var i = 0; i < columns.length; i++) {
      DateTime? firstOfMonth;
      for (final day in columns[i]) {
        if (day.day == 1) {
          firstOfMonth = day;
          break;
        }
      }
      final month =
          firstOfMonth?.month ?? (i == 0 ? columns[i].first.month : null);
      if (month == null || month == lastMonth) continue;
      lastMonth = month;
      labels.add(Positioned(
        left: i * columnWidth,
        child: Text(months[month - 1], style: style),
      ));
    }
    return SizedBox(
      width: columns.length * columnWidth,
      height: 16,
      child: Stack(clipBehavior: Clip.none, children: labels),
    );
  }
}

/// Compact bottom sheet with one day's pillar detail.
Future<void> showDayDetail(
    BuildContext context, DateTime day, PillarDay? data) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => _DayDetailSheet(day: day, data: data),
  );
}

class _DayDetailSheet extends StatelessWidget {
  final DateTime day;
  final PillarDay? data;

  const _DayDetailSheet({required this.day, required this.data});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final entry = data;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(formatDate(day.millisecondsSinceEpoch), style: t.titleLarge),
            const SizedBox(height: 4),
            Text(
              entry == null
                  ? 'Nothing logged'
                  : '${entry.pillarCount} of 4 pillars logged',
              style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final pillar in allPillars)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  entry != null && entry.hasPillar(pillar)
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: entry != null && entry.hasPillar(pillar)
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                title: Text(pillarLabel(pillar)),
                trailing: Text(
                  '${entry?.countFor(pillar) ?? 0}',
                  style: t.labelLarge?.copyWith(
                    color: entry != null && entry.hasPillar(pillar)
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen activity heatmap: last 52 weeks plus the current week, with the
/// streak/perfect-day summary and a per-day detail sheet.
class HeatmapScreen extends StatefulWidget {
  const HeatmapScreen({super.key, this.now});

  /// Injectable clock for tests.
  final DateTime Function()? now;

  @override
  State<HeatmapScreen> createState() => _HeatmapScreenState();
}

class _HeatmapScreenState extends State<HeatmapScreen> {
  Map<String, PillarDay> _days = {};
  DateTime _today = DateTime.now();
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = context.read<AppStore>();
    final now = (widget.now ?? DateTime.now)();
    final today = DateTime(now.year, now.month, now.day);
    final from = DateTime(today.year, today.month, today.day - 364);
    final to = DateTime(today.year, today.month, today.day + 1);
    try {
      final days = await store.dailyPillarActivity(from, to);
      if (!mounted) return;
      setState(() {
        _days = days;
        _today = today;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final from = DateTime(_today.year, _today.month, _today.day - 364);
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: _error != null
          ? EmptyState(
              title: 'Could not load activity',
              subtitle: _error!,
              icon: Icons.error_outline,
            )
          : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Card(
                      color: scheme.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          Expanded(
                            child: _SummaryStat(
                              value: '${currentStreak(_days, _today)}',
                              label: 'Current streak',
                            ),
                          ),
                          Expanded(
                            child: _SummaryStat(
                              value: '${longestStreak(_days)}',
                              label: 'Longest streak',
                            ),
                          ),
                          Expanded(
                            child: _SummaryStat(
                              value:
                                  '${perfectDaysInMonth(_days, _today.year, _today.month)}',
                              label: 'Perfect days this month',
                            ),
                          ),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const SectionHeader('Last 52 weeks'),
                    const SizedBox(height: 12),
                    Card(
                      color: scheme.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ActivityHeatmap(
                              days: _days,
                              start: from,
                              end: _today,
                              cellSize: 14,
                              gap: 3,
                              onDayTap: (day) => showDayDetail(
                                  context, day, _days[localDayKey(day)]),
                            ),
                            const SizedBox(height: 12),
                            const HeatmapLegend(),
                            const SizedBox(height: 8),
                            Text(
                              'Tap a square for that day\'s detail.',
                              style: t.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String value;
  final String label;

  const _SummaryStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: t.headlineSmall?.copyWith(color: scheme.primary)),
      const SizedBox(height: 4),
      Text(label,
          style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
    ]);
  }
}
