import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/activity.dart';
import '../domain/domain.dart';
import 'drawer.dart';
import 'habits.dart';
import 'health.dart';
import 'heatmap.dart';
import 'history.dart';
import 'progress.dart';
import 'settings.dart';
import 'summary.dart';
import 'widgets.dart';
import 'workout.dart';

/// The app's front door: today's four-pillar checklist, the activity heatmap
/// preview and quick links to every other area.
///
/// The checklist is the primary call to action. Logging anything (a workout, a
/// meal, a mood, a habit) calls `AppStore.refreshAll`, which notifies this
/// screen, so the checklist and heatmap update without a manual refresh.
class HomeTab extends StatefulWidget {
  const HomeTab({super.key, this.now});

  /// Injectable clock for tests.
  final DateTime Function()? now;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with WidgetsBindingObserver {
  AppStore? _store;
  Map<String, PillarDay> _days = {};
  Workout? _active;
  DateTime _today = DateTime.now();

  /// Whether this tab is the one the shell is showing. The shell keeps every
  /// tab mounted in an [IndexedStack], so without this flag a mutation on any
  /// other tab would still run this tab's aggregate queries.
  bool _visible = true;

  /// Coalesces a burst of store notifications into one reload.
  Timer? _debounce;

  /// One-shot timer for the next local midnight, so a home screen left open
  /// overnight does not keep showing yesterday's date and streak.
  Timer? _midnight;

  /// Incremented for every reload; a result whose generation is stale is
  /// dropped, so two overlapping queries cannot land out of order.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleMidnight();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.read<AppStore>();
    final visible = ShellNav.of(context).visible;
    final becameVisible = visible && !_visible;
    _visible = visible;
    if (!identical(store, _store)) {
      _store?.removeListener(_scheduleReload);
      _store = store;
      store.addListener(_scheduleReload);
      // An off-screen tab must not run the aggregate queries on first bind;
      // it catches up in the `becameVisible` branch below.
      if (_visible) _reload();
    } else if (becameVisible) {
      // The tab was off-screen while the store changed; catch up now that it
      // is visible again.
      _reload();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _midnight?.cancel();
    _store?.removeListener(_scheduleReload);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The clock may have crossed midnight while the app was backgrounded.
      _scheduleMidnight();
      if (_visible) _reload();
    }
  }

  /// Arms a one-shot timer for the next local midnight. Calendar arithmetic,
  /// not `Duration(days: 1)`: a DST transition must not make it fire an hour
  /// early or late.
  void _scheduleMidnight() {
    _midnight?.cancel();
    final now = (widget.now ?? DateTime.now)();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(
        nextMidnight.difference(now) + const Duration(seconds: 1), () {
      if (!mounted) return;
      _scheduleMidnight();
      if (_visible) _reload();
    });
  }

  /// Debounced store listener: logging a set, a meal or a habit notifies the
  /// store several times, and each notification must not cost five queries.
  void _scheduleReload() {
    // Notifications from mutations on other tabs are ignored while this tab is
    // off-screen; becoming visible reloads once with the latest data.
    if (!_visible) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      // The tab may have gone off-screen during the debounce window.
      if (_visible) _reload();
    });
  }

  Future<void> _reload() async {
    final store = _store;
    if (store == null) return;
    final generation = ++_generation;
    final now = (widget.now ?? DateTime.now)();
    final today = DateTime(now.year, now.month, now.day);
    final from = DateTime(today.year, today.month, today.day - 364);
    final to = DateTime(today.year, today.month, today.day + 1);
    try {
      final days = await store.dailyPillarActivity(from, to);
      final active = await store.activeWorkout();
      if (!mounted || generation != _generation) return;
      setState(() {
        _days = days;
        _active = active;
        _today = today;
      });
    } catch (_) {
      // A closed database (test teardown) or a transient query failure must
      // not take the front door down: the last known data stays on screen.
      if (!mounted || generation != _generation) return;
      setState(() => _today = today);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final todayEntry = _days[localDayKey(_today)];
    final streak = currentStreak(_days, _today);

    return Scaffold(
      appBar: AppBar(
        leading: const DrawerMenuButton(),
        title: Row(children: [
          TintedIconCircle(Icons.eco,
              background: scheme.primary, foreground: scheme.onPrimary),
          const SizedBox(width: 10),
          // The AppBar title is bounded by the screen width; at accessibility
          // text scales an unconstrained Text overflows the Row.
          Expanded(
            child: Text(
              'Compounder',
              style: t.titleLarge,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ),
      body: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _TodayHeader(
                  today: _today,
                  streak: streak,
                  loggedPillars: todayEntry?.pillarCount ?? 0,
                ),
                const SizedBox(height: 16),
                if (_active != null) ...[
                  Card(
                    color: scheme.primaryContainer,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      onTap: () => _openWorkout(context, _active!.id),
                      leading: Icon(Icons.play_circle_fill,
                          color: scheme.onPrimaryContainer),
                      title: Text(_active!.name,
                          style: t.headlineSmall
                              ?.copyWith(color: scheme.onPrimaryContainer)),
                      subtitle: Text(
                        'In progress since ${formatDateTime(_active!.startedAt)} · tap to resume',
                        style: TextStyle(color: scheme.onPrimaryContainer),
                      ),
                      trailing: Icon(Icons.play_arrow,
                          color: scheme.onPrimaryContainer),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                const SectionHeader('Today'),
                const SizedBox(height: 8),
                Card(
                  color: scheme.surfaceContainerLow,
                  child: Column(children: [
                    for (var i = 0; i < allPillars.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _PillarTile(
                        pillar: allPillars[i],
                        done: todayEntry?.hasPillar(allPillars[i]) ?? false,
                        onTap: () => _openPillar(context, allPillars[i]),
                      ),
                    ],
                  ]),
                ),
                const SizedBox(height: 20),
                const SectionHeader('Activity'),
                const SizedBox(height: 8),
                Card(
                  color: scheme.surfaceContainerLow,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const HeatmapScreen())),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                              child: Text('Last 12 weeks',
                                  style: t.titleMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            Icon(Icons.chevron_right, color: scheme.primary),
                          ]),
                          const SizedBox(height: 12),
                          ActivityHeatmap(
                            days: _days,
                            start: DateTime(
                                _today.year, _today.month, _today.day - 83),
                            end: _today,
                            cellSize: 6,
                            gap: 2,
                            showMonthLabels: false,
                            showWeekdayLabels: false,
                            scrollable: false,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            streak == 0
                                ? 'Tap to see your full year'
                                : '$streak-day streak · tap to see your full year',
                            style: t.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const SectionHeader('More'),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const HistoryScreen())),
                    icon: const Icon(Icons.history, size: 18),
                    label: const Text('History'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ProgressScreen())),
                    icon: const Icon(Icons.show_chart, size: 18),
                    label: const Text('Progress'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        ShellNav.of(context).selectTab?.call(tabCoach),
                    icon: const Icon(Icons.support_agent, size: 18),
                    label: const Text('Coach'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const HealthDataScreen())),
                    icon: const Icon(Icons.health_and_safety, size: 18),
                    label: const Text('Health'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        ShellNav.of(context).selectTab?.call(tabWealth),
                    icon: const Icon(Icons.insights, size: 18),
                    label: const Text('Wealth'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SettingsScreen())),
                    icon: const Icon(Icons.settings, size: 18),
                    label: const Text('Settings'),
                  ),
                ]),
                const SizedBox(height: 20),
                const HealthSummaryCard(),
                const SizedBox(height: 20),
                const SectionHeader('Recent sessions'),
                const SizedBox(height: 8),
                if (store.history.isEmpty)
                  const EmptyState(
                    title: 'No sessions yet',
                    subtitle:
                        'Create a workout and log your first lifts to see them here.',
                    icon: Icons.fitness_center,
                  )
                else
                  ...store.history.map((row) => CardRow(
                        icon: Icons.fitness_center,
                        title: row.name,
                        subtitle:
                            '${formatDate(row.startedAt)} · ${row.exerciseCount} exercises · ${row.setCount} sets',
                        trailing:
                            '${trimZero(fromKg(row.totalKg, store.unit))} ${store.unit.label}',
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => SummaryScreen(row.workoutId))),
                      )),
              ],
            ),
    );
  }

  void _openPillar(BuildContext context, int pillar) {
    switch (pillar) {
      case pillarWorkout:
        final active = _active;
        if (active != null) {
          _openWorkout(context, active.id);
        } else {
          _startWorkout(context);
        }
      case pillarNutrition:
        ShellNav.of(context).selectTab?.call(tabMacros);
      case pillarMind:
        ShellNav.of(context).selectTab?.call(tabMind);
      case pillarHabits:
        Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const HabitsScreen()));
    }
  }

  Future<void> _startWorkout(BuildContext context) async {
    final store = context.read<AppStore>();
    final name = await askWorkoutName(context);
    if (name == null) return;
    final id = await store.createWorkout(name);
    if (context.mounted) _openWorkout(context, id);
  }

  void _openWorkout(BuildContext context, int id) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => WorkoutScreen(workoutId: id)));
  }
}

class _TodayHeader extends StatelessWidget {
  final DateTime today;
  final int streak;
  final int loggedPillars;

  const _TodayHeader({
    required this.today,
    required this.streak,
    required this.loggedPillars,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    // Stacked rather than a Row: at accessibility text scales the fixed-width
    // streak chip beside an Expanded column overflowed by 31px at 320dp/2.0.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(formatDate(today.millisecondsSinceEpoch), style: t.titleLarge),
      const SizedBox(height: 4),
      Text(
        loggedPillars == 0
            ? 'Nothing logged yet today'
            : '$loggedPillars of 4 pillars logged today',
        style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.local_fire_department,
              size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              streak == 0 ? 'No streak' : '$streak-day streak',
              style: t.labelLarge?.copyWith(color: scheme.onSecondaryContainer),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _PillarTile extends StatelessWidget {
  final int pillar;
  final bool done;
  final VoidCallback onTap;

  const _PillarTile({
    required this.pillar,
    required this.done,
    required this.onTap,
  });

  IconData get _icon => switch (pillar) {
        pillarWorkout => Icons.fitness_center,
        pillarNutrition => Icons.restaurant,
        pillarMind => Icons.psychology,
        pillarHabits => Icons.checklist_rtl,
        _ => Icons.circle,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: onTap,
      leading: TintedIconCircle(
        _icon,
        background: done ? scheme.primary : scheme.surfaceContainerHighest,
        foreground: done ? scheme.onPrimary : scheme.onSurfaceVariant,
      ),
      title: Text(pillarLabel(pillar), style: t.titleMedium),
      subtitle: Text(
        done ? 'Logged today' : 'Not yet — tap to log',
        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: Icon(
        done ? Icons.check_circle : Icons.chevron_right,
        color: done ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}
