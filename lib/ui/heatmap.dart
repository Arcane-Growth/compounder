import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import '../domain/activity.dart';
import 'widgets.dart';

/// GitHub-style activity heatmap over the app's five logging pillars.
///
/// Intensity is the number of distinct pillars logged on a local calendar day
/// (0-5), computed by [PillarDay.intensity]. The grid is a dense visualisation,
/// so individual squares are smaller than the 48dp touch-target guideline;
/// every square carries a [Semantics] label and the full screen also offers the
/// per-day detail sheet, which is the accessible path to the same information.

/// The colour ramp for intensity 0-5, theme aware.
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
    Color(0xFF0B3D1F),
  ];
  const darkRamp = [
    Color(0xFF0E4429),
    Color(0xFF006D32),
    Color(0xFF26A641),
    Color(0xFF39D353),
    Color(0xFF7BF5A0),
  ];
  final ramp = dark ? darkRamp : lightRamp;
  return ramp[(intensity - 1).clamp(0, 4)];
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
      label: '$key: $intensity of 5 pillars logged',
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
    final labelStyle = t.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    // Wrap, not Row: five swatches plus "Less"/"More" overflowed by 24px at
    // 320dp/2.0. Wrapping keeps every swatch visible at accessibility scales.
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Less', style: labelStyle),
        for (var i = 0; i <= 5; i++)
          Container(
            width: swatchSize,
            height: swatchSize,
            decoration: BoxDecoration(
              color: heatmapColor(context, i),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        Text('More', style: labelStyle),
      ],
    );
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

  /// Controller for the horizontal grid. [HeatmapScreen] uses it to open on
  /// the newest week instead of 52 weeks ago.
  final ScrollController? controller;
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
    this.controller,
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

    final gridColumns = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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

    // Month labels and the grid share one column origin: the label row sits
    // directly above the grid inside the same Column, and the weekday gutter
    // is a sibling. Positioning the labels from x=0 while the grid started
    // after the weekday labels put every month label over the gutter.
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showMonthLabels) const SizedBox(height: 16),
                if (showWeekdayLabels) _weekdayLabels(context),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showMonthLabels)
                  _monthLabels(context, columns, columnWidth, start, end),
                gridColumns,
              ],
            ),
          ],
        ),
        if (showLegend) ...[
          const SizedBox(height: 12),
          const HeatmapLegend(),
        ],
      ],
    );

    if (!scrollable) return content;
    return SingleChildScrollView(
      controller: controller,
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

  Widget _monthLabels(BuildContext context, List<List<DateTime>> columns,
      double columnWidth, DateTime first, DateTime last) {
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
        // A week column can extend past the requested range (the grid is
        // padded to whole weeks). A month that starts in that padding must
        // not be labelled: it is outside the range the user asked for.
        if (day.isBefore(first) || day.isAfter(last)) continue;
        if (day.day == 1) {
          firstOfMonth = day;
          break;
        }
      }
      final month = firstOfMonth?.month ?? (i == 0 ? first.month : null);
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
        // Five pillar rows no longer fit a compact bottom sheet at large text
        // scales, so the content scrolls instead of overflowing.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(formatDate(day.millisecondsSinceEpoch), style: t.titleLarge),
              const SizedBox(height: 4),
              Text(
                entry == null
                    ? 'Nothing logged'
                    : '${entry.pillarCount} of 5 pillars logged',
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

class _HeatmapScreenState extends State<HeatmapScreen>
    with WidgetsBindingObserver {
  AppStore? _store;
  Map<String, PillarDay> _days = {};
  DateTime _today = DateTime.now();
  String? _error;

  /// Coalesces a burst of store notifications into one reload.
  Timer? _debounce;

  /// One-shot timer for the next local midnight, so a screen left open
  /// overnight does not keep showing yesterday's summary.
  Timer? _midnight;

  /// Incremented for every load; a result whose generation is stale is
  /// dropped, so two overlapping queries cannot land out of order.
  int _generation = 0;

  /// Drives the 53-week grid. The grid is far wider than the screen, and the
  /// newest week is at the right edge: without pinning it the screen opens on
  /// the oldest week and every visible square is empty.
  final ScrollController _gridScroll = ScrollController();

  /// Set once the grid has been pinned to the newest week, so a later rebuild
  /// (or the grid scrolling back into view) does not fight the user's own
  /// horizontal position.
  bool _pinnedToNewest = false;

  /// The [ScrollPosition] the grid was last pinned on.
  ///
  /// The grid subtree is torn down whenever the error branch replaces it with
  /// the retry column, and "Try again" rebuilds it with a fresh position at
  /// offset 0. Comparing identity lets the metrics listener notice that and
  /// re-pin, instead of trusting a flag that describes a position that no
  /// longer exists (which would leave the screen on the oldest week).
  ScrollPosition? _pinnedPosition;

  /// Viewport width of the grid at the last pin, used to detect a resize or
  /// rotation that must re-pin.
  double? _gridViewportWidth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleMidnight();
    _pinGridToNewest();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.read<AppStore>();
    if (!identical(store, _store)) {
      _store?.removeListener(_scheduleReload);
      _store = store;
      store.addListener(_scheduleReload);
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _midnight?.cancel();
    _store?.removeListener(_scheduleReload);
    _gridScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleMidnight();
      _load();
    }
  }

  /// Arms a one-shot timer for the next local midnight. Calendar arithmetic,
  /// not `Duration(days: 1)`: a DST transition must not make it fire an hour
  /// early or late.
  void _scheduleMidnight() {
    _midnight?.cancel();
    final now = (widget.now ?? DateTime.now)();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnight =
        Timer(nextMidnight.difference(now) + const Duration(seconds: 1), () {
      if (!mounted) return;
      _scheduleMidnight();
      _load();
    });
  }

  /// Debounced store listener: a background sync or a log made while this
  /// screen is open must refresh it, but a burst of notifications must not
  /// run the aggregate queries once per notification.
  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _load);
  }

  /// Jumps the grid to its right edge (the current week) after the next frame.
  ///
  /// Post-frame because the grid's extent is only known once it has been laid
  /// out; the screen's own ListView builds it lazily, so this is also called
  /// from the metrics listener when the grid first appears.
  void _pinGridToNewest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_gridScroll.hasClients) return;
      final max = _gridScroll.position.maxScrollExtent;
      if (max <= 0) return;
      _pinnedToNewest = true;
      if ((_gridScroll.offset - max).abs() < 0.5) return;
      _gridScroll.jumpTo(max);
    });
  }

  /// Pins the grid on its first layout and again whenever its viewport width
  /// changes (rotation, split-screen, a desktop window resize).
  bool _onGridMetrics(ScrollMetricsNotification notification) {
    if (notification.depth != 0) return false;
    // A different position means the grid was rebuilt from scratch (the error
    // branch tore it down, or the whole subtree was replaced): the pin no
    // longer applies, so re-pin on this layout.
    final position = _gridScroll.hasClients ? _gridScroll.position : null;
    if (position != _pinnedPosition) {
      _pinnedPosition = position;
      _pinnedToNewest = false;
    }
    final width = notification.metrics.viewportDimension;
    final resized = _gridViewportWidth != null && _gridViewportWidth != width;
    _gridViewportWidth = width;
    if (!_pinnedToNewest || resized) _pinGridToNewest();
    return false;
  }

  Future<void> _load() async {
    final store = _store;
    if (store == null) return;
    final generation = ++_generation;
    final now = (widget.now ?? DateTime.now)();
    final today = DateTime(now.year, now.month, now.day);
    final from = DateTime(today.year, today.month, today.day - 364);
    final to = DateTime(today.year, today.month, today.day + 1);
    try {
      final days = await store.dailyPillarActivity(from, to);
      if (!mounted || generation != _generation) return;
      setState(() {
        _days = days;
        _today = today;
        _error = null;
      });
    } catch (e) {
      // A load that lands after the screen is gone (or after a newer load
      // started) is irrelevant: do not log it or touch state.
      if (!mounted || generation != _generation) return;
      // Keep the raw error for the log; the user gets a human message.
      debugPrint('HeatmapScreen: activity load failed: $e');
      setState(() =>
          _error = 'Your activity could not be loaded. Try again in a moment.');
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
          ? Column(children: [
              EmptyState(
                title: 'Could not load activity',
                subtitle: _error!,
                icon: Icons.error_outline,
              ),
              FilledButton(
                onPressed: _load,
                child: const Text('Try again'),
              ),
            ])
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
                        NotificationListener<ScrollMetricsNotification>(
                          onNotification: _onGridMetrics,
                          child: ActivityHeatmap(
                            days: _days,
                            start: from,
                            end: _today,
                            cellSize: 14,
                            gap: 3,
                            controller: _gridScroll,
                            onDayTap: (day) => showDayDetail(
                                context, day, _days[localDayKey(day)]),
                          ),
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
                const SizedBox(height: 20),
                const SectionHeader('Recent days'),
                const SizedBox(height: 8),
                Card(
                  color: scheme.surfaceContainerLow,
                  child: Column(children: [
                    for (var i = 0; i < 7; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _DayRow(
                        day:
                            DateTime(_today.year, _today.month, _today.day - i),
                        data: _days[localDayKey(DateTime(
                            _today.year, _today.month, _today.day - i))],
                      ),
                    ],
                  ]),
                ),
              ],
            ),
    );
  }
}

/// One accessible per-day row: a 48dp [ListTile] that opens the same detail
/// sheet as a heatmap square. The 14px squares are a dense visualisation, so
/// this list is the touch-target-sized path to the same information.
class _DayRow extends StatelessWidget {
  final DateTime day;
  final PillarDay? data;

  const _DayRow({required this.day, required this.data});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final entry = data;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: () => showDayDetail(context, day, entry),
      title: Text(formatDate(day.millisecondsSinceEpoch), style: t.titleMedium),
      subtitle: Text(
        entry == null
            ? 'Nothing logged'
            : '${entry.pillarCount} of 5 pillars logged',
        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
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
